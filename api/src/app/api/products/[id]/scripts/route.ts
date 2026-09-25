import { randomUUID } from "node:crypto";
import { verifySession } from "@/lib/session";
import { supabaseAdmin } from "@/lib/supabase";
import { ProductError, readLimitedBody } from "@/lib/products";
import { generateVideoScripts } from "@/lib/ai/anthropic";
import { parseOutputLanguage } from "@/lib/ai/types";
import { type VideoScript } from "@/lib/scripts";
import { billingConfig } from "@/lib/billing-config";
import { assertCanAfford, chargeCredits, balanceOf, InsufficientCreditsError } from "@/lib/credits";
import { json, error } from "@/lib/http";

export const maxDuration = 120;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MARKETPLACE = "video";

type ProductRow = { id: string; name: string; category: string | null; attributes: Record<string, unknown> };

async function ownedProduct(orgId: string, id: string): Promise<ProductRow | null> {
  const { data } = await supabaseAdmin().from("products")
    .select("id, name, category, attributes").eq("id", id).eq("org_id", orgId).maybeSingle();
  return (data as ProductRow) ?? null;
}

function keyFeaturesOf(row: ProductRow): string[] {
  const raw = row.attributes?.keyFeatures;
  return Array.isArray(raw) ? raw.filter((f): f is string => typeof f === "string") : [];
}

/** The stored video scripts for this product. */
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  let claims;
  try { claims = await verifySession(request.headers.get("authorization")); }
  catch { return error("Not authorized.", 401); }
  const { id } = await context.params;
  if (!UUID.test(id)) return error("That product could not be found.", 404);
  const db = supabaseAdmin();
  const product = await ownedProduct(claims.orgId, id);
  if (!product) return error("That product could not be found.", 404);

  const { data, error: dbError } = await db.from("assets")
    .select("id, content, created_at").eq("product_id", id).eq("marketplace", MARKETPLACE)
    .order("created_at", { ascending: true });
  if (dbError) return error("Could not load the scripts.", 500);
  return json({ scripts: decodeScripts(data ?? []) });
}

/** Generate a fresh set of video scripts, replacing any previous set. */
export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  let claims;
  try { claims = await verifySession(request.headers.get("authorization")); }
  catch { return error("Not authorized.", 401); }
  const { id } = await context.params;
  if (!UUID.test(id)) return error("That product could not be found.", 404);

  let body;
  try { body = JSON.parse((await readLimitedBody(request, 2048)).toString("utf8")); }
  catch (e) { return error(e instanceof ProductError ? e.message : "Invalid request body."); }
  const count = Number.isInteger(body?.count) && body.count >= 1 && body.count <= 5 ? body.count : 5;
  const language = parseOutputLanguage(body?.language);
  if (!language) return error("That language is not supported yet.");

  const db = supabaseAdmin();
  const product = await ownedProduct(claims.orgId, id);
  if (!product) return error("That product could not be found.", 404);

  const cost = billingConfig.costs.adScript;
  try {
    await assertCanAfford(claims.orgId, cost * count);
    const scripts = await generateVideoScripts({
      name: product.name,
      category: product.category ?? "",
      keyFeatures: keyFeaturesOf(product),
      count,
      language,
      makeId: () => randomUUID(),
    });
    if (scripts.length === 0) return error("No usable scripts were produced. Please retry.", 502);

    // Replace the previous set so the product always shows one coherent batch.
    await db.from("assets").delete().eq("product_id", id).eq("marketplace", MARKETPLACE);
    const rows = scripts.map((script) => ({
      id: script.id, product_id: id, type: "script", marketplace: MARKETPLACE,
      url: null, content: JSON.stringify(script), validation_status: "pass", violations: [],
    }));
    const { error: insertError } = await db.from("assets").insert(rows);
    if (insertError) return error("Could not save the scripts. Please retry.", 500);

    await chargeCredits(claims.orgId, cost * scripts.length, "generation.script");
    const { balance } = await balanceOf(claims.orgId);
    return json({ scripts, creditsCharged: cost * scripts.length, balanceAfter: balance });
  } catch (e) {
    if (e instanceof InsufficientCreditsError) return json({ error: e.message, required: e.required, available: e.available }, 402);
    return error("Script generation failed. Please retry this request.", 500);
  }
}

function decodeScripts(rows: { id: string; content: string | null }[]): VideoScript[] {
  const out: VideoScript[] = [];
  for (const row of rows) {
    if (!row.content) continue;
    try {
      const parsed = JSON.parse(row.content) as VideoScript;
      if (parsed?.hook && Array.isArray(parsed.scenes)) out.push({ ...parsed, id: row.id });
    } catch { /* skip a corrupt row rather than failing the whole list */ }
  }
  return out;
}
