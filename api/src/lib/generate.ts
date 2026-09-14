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
import { CREDIT_COST, InsufficientCreditsError } from "./credits.ts";
import { createHash } from "node:crypto";
import { rulesFor } from "./rules/registry.ts";
import { statusOf, validate } from "./rules/validate.ts";
import type { MarketplaceId, Violation } from "./rules/types.ts";
import { CUTOUT_BUCKET } from "./products.ts";
import { supabaseAdmin } from "./supabase.ts";

/** Title plus description, per marketplace. */
const CREDITS_PER_MARKETPLACE = CREDIT_COST.titleOrDescription * 2;

export interface GenerateInput {
  requestId?: string;
  productId: string;
  marketplaces: MarketplaceId[];
  /** 0 skips ad scripts entirely. */
  scriptCount: number;
}

export interface GeneratedAsset {
  id?: string;
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

  if (!input.requestId) throw new GenerationRequestError("This generation needs a request identifier.", 400);
  if (product.attributes?.captureStatus === "uploading") throw new GenerationRequestError("Finish uploading your photos first.", 409);
  const immutableInput = { marketplaces: input.marketplaces, scriptCount: input.scriptCount };
  const inputHash = createHash("sha256").update(JSON.stringify(immutableInput)).digest("hex");
  const { data: reservation, error: reserveError } = await db.rpc("begin_generation", {
    p_request_id: input.requestId, p_org_id: orgId, p_product_id: input.productId,
    p_input_hash: inputHash, p_input: immutableInput, p_quoted_credits: quoteCredits(input),
  });
  if (reserveError) throw new GenerationRequestError("Generation is temporarily unavailable. Please try again.", 503);
  if (reservation.status === "completed") return reservation.result as GenerateResult;
  if (reservation.status === "running") throw new GenerationRequestError("Your listing is still being generated. Check again shortly.", 409);
  if (reservation.status === "insufficient") throw new InsufficientCreditsError(reservation.required, reservation.available);
  if (reservation.status === "not_found") throw new GenerationRequestError("That product could not be found.", 404);
  if (reservation.status === "conflict") throw new GenerationRequestError("This request belongs to a different selection. Start a new generation.", 409);
  if (reservation.status !== "started") throw new GenerationRequestError("This account is unavailable.", 403);
  const leaseToken = reservation.leaseToken as string;
  try {
  const usages: (ModelUsage & { creditsCharged: number })[] = [];
  const visionUsages: ModelUsage[] = [];
  const facts = await describeProduct(product, visionUsages);
  usages.push(...visionUsages.map(usage => ({ ...usage, creditsCharged: 0 })));

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
      const usage = { ...copy.usage, creditsCharged: 0 };
      usages.push(usage);

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
      usage.creditsCharged = CREDITS_PER_MARKETPLACE;
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
      const usage = { ...scripts.usage, creditsCharged: 0 };
      usages.push(usage);

      const completedScripts = scripts.value.slice(0, input.scriptCount);
      for (const script of completedScripts) {
        assets.push({
          type: "script",
          marketplace: input.marketplaces[0],
          content: [script.hook, ...script.beats].join("\n"),
          status: "pass",
          violations: [],
        });
      }
      const scriptCredits = completedScripts.length * CREDIT_COST.adScript;
      usage.creditsCharged = scriptCredits;
      creditsCharged += scriptCredits;
    } catch (error) {
      failures.push({
        marketplace: "scripts",
        reason: error instanceof Error ? error.message : "Scripts failed.",
      });
    }
  }

  const response = { productId: product.id as string, facts, assets, failures, creditsCharged, balanceAfter: 0 };
  const { data: settled, error: settlementError } = await db.rpc("complete_generation", {
    p_request_id: input.requestId, p_lease_token: leaseToken, p_assets: assets,
    p_usages: usages, p_result: response, p_credits_to_charge: creditsCharged,
  });
  if (settlementError) throw new GenerationRequestError("We could not confirm your listing. Check this request again before starting another.", 503);
  return settled as GenerateResult;
  } catch (error) {
    // Completion may have committed even if its response was lost. The RPC only
    // releases a still-running lease, never a completed debit/result.
    await db.rpc("fail_generation", { p_request_id: input.requestId, p_lease_token: leaseToken });
    throw error;
  }
}

export class GenerationRequestError extends Error {
  readonly status: number;
  constructor(message: string, status: number) { super(message); this.status = status; }
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
    if (error || !data) throw new Error("Your photo could not be loaded. Retry this listing.");
    if (data) {
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
