// Composes the whole generation step: photo → facts → listing copy → validated
// assets → ledger.
//
// Credit handling follows SPEC §6 exactly: the balance is checked before any
// model is called, and credits are charged per unit of work that actually
// succeeded. Nothing is charged up front, so there is nothing to refund when a
// marketplace fails half way through.

import {
  AnthropicListingProvider,
  AnthropicScriptProvider,
  AnthropicVisionProvider,
} from "./ai/anthropic.ts";
import type { ModelUsage, ProductFacts } from "./ai/types.ts";
import { CREDIT_COST, assertCanAfford, balanceOf, chargeCredits } from "./credits.ts";
import { rulesFor } from "./rules/registry.ts";
import { statusOf, validate } from "./rules/validate.ts";
import type { MarketplaceId, Violation } from "./rules/types.ts";
import { CUTOUT_BUCKET } from "./products.ts";
import { supabaseAdmin } from "./supabase.ts";

/** Title plus description, per marketplace. */
const CREDITS_PER_MARKETPLACE = CREDIT_COST.titleOrDescription * 2;

export interface GenerateInput {
  productId: string;
  marketplaces: MarketplaceId[];
  /** 0 skips ad scripts entirely. */
  scriptCount: number;
}

export interface GeneratedAsset {
  type: "title" | "description" | "script";
  marketplace: string;
  content: string;
  status: "pass" | "warn" | "fail";
  violations: Violation[];
}

export interface GenerateResult {
  productId: string;
  facts: ProductFacts;
  assets: GeneratedAsset[];
  /** Marketplaces that failed, with the reason. Partial success is normal. */
  failures: { marketplace: string; reason: string }[];
  creditsCharged: number;
  balanceAfter: number;
}

/** What the work will cost, quoted before anything runs (design step 3). */
export function quoteCredits(input: GenerateInput): number {
  return (
    input.marketplaces.length * CREDITS_PER_MARKETPLACE +
    Math.max(0, input.scriptCount) * CREDIT_COST.adScript
  );
}

export async function generateListings(orgId: string, input: GenerateInput): Promise<GenerateResult> {
  if (input.marketplaces.length === 0) throw new Error("Pick at least one marketplace.");

  const db = supabaseAdmin();

  const { data: product, error: productError } = await db
    .from("products")
    .select("id, name, category, cutout_url, attributes")
    .eq("id", input.productId)
    .eq("org_id", orgId)
    .maybeSingle();
  if (productError) throw new Error(productError.message);
  if (!product) throw new Error("That product could not be found.");

  // Before any model runs (SPEC §6).
  await assertCanAfford(orgId, quoteCredits(input));

  const usages: ModelUsage[] = [];
  const facts = await describeProduct(product, usages);

  const assets: GeneratedAsset[] = [];
  const failures: { marketplace: string; reason: string }[] = [];
  let creditsCharged = 0;

  for (const marketplace of input.marketplaces) {
    try {
      const rules = rulesFor(marketplace);

      const copy = await new AnthropicListingProvider().writeListing({
        facts,
        marketplaceName: rules.displayName,
        constraints: {
          titleMaxChars: rules.title?.maxChars,
          bulletFormat: rules.description?.format === "bullets",
          maxBullets: rules.description?.maxBullets,
          maxCharsPerBullet: rules.description?.maxCharsPerBullet,
          forbidPromoLanguage: rules.title?.forbid?.includes("promoLanguage") ?? false,
          forbidAllCaps: rules.title?.forbid?.includes("allCaps") ?? false,
        },
      });
      usages.push(copy.usage);

      // The generated copy is judged by the same engine that judges a seller's
      // own text — the model is not trusted to have followed the limits.
      const titleViolations = validate({ type: "title", text: copy.value.title }, rules);
      assets.push({
        type: "title",
        marketplace,
        content: copy.value.title,
        status: statusOf(titleViolations),
        violations: titleViolations,
      });

      const descriptionAsset =
        copy.value.bullets.length > 0
          ? { type: "description" as const, bullets: copy.value.bullets }
          : { type: "description" as const, text: copy.value.description ?? "" };
      const descriptionViolations = validate(descriptionAsset, rules);
      assets.push({
        type: "description",
        marketplace,
        content: copy.value.bullets.length > 0
          ? copy.value.bullets.join("\n")
          : copy.value.description ?? "",
        status: statusOf(descriptionViolations),
        violations: descriptionViolations,
      });

      // Charged only now that this marketplace produced something.
      await chargeCredits(orgId, CREDITS_PER_MARKETPLACE, "generation.title");
      creditsCharged += CREDITS_PER_MARKETPLACE;
    } catch (error) {
      failures.push({
        marketplace,
        reason: error instanceof Error ? error.message : "Generation failed.",
      });
    }
  }

  if (input.scriptCount > 0) {
    try {
      const scripts = await new AnthropicScriptProvider().writeAdScripts({
        facts,
        marketplace: rulesFor(input.marketplaces[0]).displayName,
        count: input.scriptCount,
      });
      usages.push(scripts.usage);

      for (const script of scripts.value) {
        assets.push({
          type: "script",
          marketplace: input.marketplaces[0],
          content: [script.hook, ...script.beats].join("\n"),
          status: "pass",
          violations: [],
        });
      }
      const scriptCredits = scripts.value.length * CREDIT_COST.adScript;
      await chargeCredits(orgId, scriptCredits, "generation.script");
      creditsCharged += scriptCredits;
    } catch (error) {
      failures.push({
        marketplace: "scripts",
        reason: error instanceof Error ? error.message : "Scripts failed.",
      });
    }
  }

  await persist(orgId, product.id as string, assets, usages);

  const { balance } = await balanceOf(orgId);

  return {
    productId: product.id as string,
    facts,
    assets,
    failures,
    creditsCharged,
    balanceAfter: balance,
  };
}

/** Reads the cutout and asks Claude what the product is. */
async function describeProduct(
  product: { cutout_url: unknown; name: unknown; category: unknown; attributes: unknown },
  usages: ModelUsage[],
): Promise<ProductFacts> {
  const path = typeof product.cutout_url === "string" ? product.cutout_url : null;

  if (path) {
    const db = supabaseAdmin();
    const { data, error } = await db.storage.from(CUTOUT_BUCKET).download(path);
    if (!error && data) {
      const vision = await new AnthropicVisionProvider().readProduct({
        bytes: new Uint8Array(await data.arrayBuffer()),
        mediaType: "image/png",
      });
      usages.push(vision.usage);
      return vision.value;
    }
  }

  // No photo: fall back to what the seller typed rather than refusing outright.
  const attributes = (product.attributes ?? {}) as { keyFeatures?: unknown };
  return {
    suggestedName: String(product.name ?? ""),
    suggestedCategory: String(product.category ?? ""),
    keyFeatures: Array.isArray(attributes.keyFeatures)
      ? attributes.keyFeatures.filter((f): f is string => typeof f === "string")
      : [],
    visibleText: [],
  };
}

/** Writes the asset rows and one generations row per model call (SPEC §9). */
async function persist(
  orgId: string,
  productId: string,
  assets: GeneratedAsset[],
  usages: ModelUsage[],
): Promise<void> {
  const db = supabaseAdmin();

  if (assets.length > 0) {
    const { error } = await db.from("assets").insert(
      assets.map((asset) => ({
        product_id: productId,
        type: asset.type,
        marketplace: asset.marketplace,
        content: asset.content,
        validation_status: asset.status,
        violations: asset.violations,
      })),
    );
    if (error) throw new Error(error.message);
  }

  if (usages.length > 0) {
    // actual_cost_usd stays null when the model's rate is unknown — never 0.
    const { error } = await db.from("generations").insert(
      usages.map((usage) => ({
        org_id: orgId,
        provider: usage.provider,
        model: usage.model,
        credits_charged: 0,
        actual_cost_usd: usage.costUSD,
        latency_ms: usage.latencyMs,
        langfuse_trace_id: usage.traceId,
      })),
    );
    if (error) throw new Error(error.message);
  }
}
