import { billingStatus, BillingError } from "@/lib/billing";
import { verifySession } from "@/lib/session";
import { generateListings, GenerationRequestError, quoteCredits } from "@/lib/generate";
import { InsufficientCreditsError } from "@/lib/credits";
import { MARKETPLACE_IDS } from "@/lib/rules/registry";
import type { MarketplaceId } from "@/lib/rules/types";
import { parseOutputLanguage } from "@/lib/ai/types";
import { supabaseAdmin } from "@/lib/supabase";
import { ProductError, readLimitedBody } from "@/lib/products";
import { json, error } from "@/lib/http";

export const maxDuration = 300;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function selection(raw: unknown, scripts: unknown): { marketplaces: MarketplaceId[]; scriptCount: number } | null {
  if (!Array.isArray(raw) || raw.length > 4 || raw.some(m => !MARKETPLACE_IDS.includes(m))) return null;
  const marketplaces = [...new Set(raw)] as MarketplaceId[];
  if (!Number.isInteger(scripts) || Number(scripts) < 0 || Number(scripts) > 10) return null;
  return { marketplaces, scriptCount: Number(scripts) };
}

export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  let claims;
  try { claims = await verifySession(request.headers.get("authorization")); }
  catch { return error("Not authorized.", 401); }
  const { id } = await context.params;
  if (!UUID.test(id)) return error("That product could not be found.", 404);
  let body;
  try { body = JSON.parse((await readLimitedBody(request, 16384)).toString("utf8")); }
  catch (e) { return error(e instanceof ProductError ? e.message : "Invalid request body."); }
  if (!body || typeof body !== "object" || typeof body.requestId !== "string" || !UUID.test(body.requestId)) {
    return error("This generation needs a request identifier.");
  }
  const input = selection(body.marketplaces, body.scriptCount ?? 0);
  if (!input || !input.marketplaces.length) return error("Choose up to four marketplaces and 0–10 scripts.");
  const language = parseOutputLanguage(body.language);
  if (!language) return error("That language is not supported yet.");
  try {
    const plan = await billingStatus(claims.orgId, claims.userId);
    if (input.marketplaces.some(m => !plan.allowedMarketplaces.includes(m))) return error("Choose Pro or Scale to generate for this marketplace.", 403);
    return json(await generateListings(claims.orgId, { productId: id, requestId: body.requestId, ...input, language }));
  } catch (e) {
    if (e instanceof InsufficientCreditsError) return error(e.message, 402, { required: e.required, available: e.available });
    if (e instanceof BillingError) return error(e.message, e.status);
    if (e instanceof GenerationRequestError) return error(e.message, e.status);
    return error("Generation failed. Please retry this request.", 500);
  }
}

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  let claims;
  try { claims = await verifySession(request.headers.get("authorization")); }
  catch { return error("Not authorized.", 401); }
  const { id } = await context.params;
  const db = supabaseAdmin();
  const { data: product, error: lookupError } = await db.from("products").select("id")
    .eq("id", id).eq("org_id", claims.orgId).maybeSingle();
  if (lookupError) return error("Could not load this product.", 500);
  if (!product) return error("That product could not be found.", 404);
  const url = new URL(request.url);
  const requestId = url.searchParams.get("requestId");
  if (requestId) {
    if (!UUID.test(requestId)) return error("Invalid generation request.");
    const { data, error: readError } = await db.from("generation_requests").select("status,result,lease_expires_at")
      .eq("id", requestId).eq("org_id", claims.orgId).eq("product_id", id).maybeSingle();
    if (readError) return error("Could not check this generation. Try again.", 503);
    if (!data) return error("That generation has not started.", 404);
    if (data.status === "completed") return json(data.result);
    if (data.status === "running" && Date.parse(data.lease_expires_at) > Date.now()) {
      return error("Your listing is still being generated. Check again shortly.", 409);
    }
    return error("This generation did not finish. Retry the same request.", 410);
  }
  const raw = url.searchParams.get("marketplaces") ?? "";
  const input = selection(raw ? raw.split(",") : [], Number(url.searchParams.get("scriptCount") ?? 0));
  if (!input) return error("Choose up to four marketplaces and 0–10 scripts.");
  return json({ credits: quoteCredits({ productId: id, ...input }) });
}
