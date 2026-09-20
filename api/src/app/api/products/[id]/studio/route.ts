import { createHash } from "node:crypto";
import { verifySession } from "@/lib/session";
import { supabaseAdmin } from "@/lib/supabase";
import { CUTOUT_BUCKET, ProductError, readLimitedBody } from "@/lib/products";
import { isIndustry, findScene, publicCatalog } from "@/lib/studio";
import { composeScene, ImageError } from "@/lib/ai/image";
import { billingConfig } from "@/lib/billing-config";
import { assertCanAfford, chargeCredits, balanceOf, InsufficientCreditsError } from "@/lib/credits";
import { json, error } from "@/lib/http";

// A scene can take Kling well over a minute; keep requests to a few scenes.
export const maxDuration = 300;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SIGNED_URL_TTL = 3600;

/** Stable asset id per (org, product, scene) so retries don't duplicate rows. */
function studioAssetID(orgId: string, productId: string, sceneId: string): string {
  const bytes = createHash("sha256").update(`listingforge:studio:${orgId}:${productId}:${sceneId}`).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const h = bytes.toString("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

async function signed(path: string): Promise<string | null> {
  const { data } = await supabaseAdmin().storage.from(CUTOUT_BUCKET).createSignedUrl(path, SIGNED_URL_TTL);
  return data?.signedUrl ?? null;
}

/** List the industries/scenes on offer, plus any studio images already made. */
export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  let claims;
  try { claims = await verifySession(request.headers.get("authorization")); }
  catch { return error("Not authorized.", 401); }
  const { id } = await context.params;
  if (!UUID.test(id)) return error("That product could not be found.", 404);
  const db = supabaseAdmin();
  const { data: product } = await db.from("products").select("id").eq("id", id).eq("org_id", claims.orgId).maybeSingle();
  if (!product) return error("That product could not be found.", 404);

  const { data: rows } = await db.from("assets").select("id, marketplace, url")
    .eq("product_id", id).like("marketplace", "studio:%");
  const images = await Promise.all((rows ?? []).map(async (r) => {
    const [sceneId, indexStr] = (r.marketplace as string).slice("studio:".length).split(":");
    return {
      sceneId,
      index: Number(indexStr) || 0,
      assetId: r.id as string,
      url: await signed(r.url as string),
    };
  }));
  return json({ creditsPerImage: billingConfig.costs.imageGeneration, catalog: publicCatalog(), images });
}

/** Generate studio backdrops for the chosen scenes. */
export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  let claims;
  try { claims = await verifySession(request.headers.get("authorization")); }
  catch { return error("Not authorized.", 401); }
  const { id } = await context.params;
  if (!UUID.test(id)) return error("That product could not be found.", 404);

  let body;
  try { body = JSON.parse((await readLimitedBody(request, 4096)).toString("utf8")); }
  catch (e) { return error(e instanceof ProductError ? e.message : "Invalid request body."); }
  if (!body || typeof body !== "object" || !isIndustry(body.industry)) {
    return error("Choose an industry.");
  }
  const scene = typeof body.sceneId === "string" ? findScene(body.industry, body.sceneId) : undefined;
  if (!scene) return error("Choose a studio style available for this industry.");
  const count = [1, 3, 5].includes(body.count) ? (body.count as number) : 3;

  const db = supabaseAdmin();
  const { data: product, error: lookupError } = await db.from("products")
    .select("id, cutout_url").eq("id", id).eq("org_id", claims.orgId).maybeSingle();
  if (lookupError) return error("Could not load this product.", 500);
  if (!product) return error("That product could not be found.", 404);
  if (!product.cutout_url) return error("Capture a product photo before generating studio shots.");

  // Each angle is a distinct variation of the chosen style. Skip any already
  // made so a retry never regenerates or double-charges.
  const variationKey = (n: number) => `${scene.id}:${n}`;
  const wanted = Array.from({ length: count }, (_, n) => n);
  const assetIds = wanted.map((n) => studioAssetID(claims.orgId, id, variationKey(n)));
  const { data: existingRows } = await db.from("assets").select("id, url").in("id", assetIds);
  const existing = new Map((existingRows ?? []).map((r) => [r.id as string, r.url as string]));
  const todo = wanted.filter((n) => !existing.has(studioAssetID(claims.orgId, id, variationKey(n))));

  const cost = billingConfig.costs.imageGeneration;
  try {
    if (todo.length) await assertCanAfford(claims.orgId, cost * todo.length);

    const { data: cutout, error: downloadError } = await db.storage.from(CUTOUT_BUCKET).download(product.cutout_url);
    if (downloadError || !cutout) return error("The product photo is not available. Retry the capture.", 409);
    const subject = { data: Buffer.from(await cutout.arrayBuffer()), mime: "image/png" };

    let generated = 0;
    for (const n of todo) {
      const result = await composeScene(subject, scene);
      const path = `${claims.orgId}/${id}/studio/${scene.id}-${n}.png`;
      const up = await db.storage.from(CUTOUT_BUCKET).upload(path, result.data, { contentType: result.mime, upsert: true });
      if (up.error) throw new ImageError("Could not save the generated image. Retry this style.");
      const { error: insertError } = await db.from("assets").upsert({
        id: studioAssetID(claims.orgId, id, variationKey(n)), product_id: id, type: "image",
        marketplace: `studio:${variationKey(n)}`, url: path, validation_status: "pass", violations: [],
      }, { onConflict: "id" });
      if (insertError) throw new ImageError("Could not save the generated image. Retry this style.");
      // Charge per image as it lands, so a mid-batch failure only bills success.
      await chargeCredits(claims.orgId, cost, "generation.image");
      existing.set(studioAssetID(claims.orgId, id, variationKey(n)), path);
      generated += 1;
    }

    const images = await Promise.all(wanted.map(async (n) => {
      const path = existing.get(studioAssetID(claims.orgId, id, variationKey(n)))!;
      return { sceneId: scene.id, index: n, assetId: studioAssetID(claims.orgId, id, variationKey(n)), url: await signed(path) };
    }));
    const { balance } = await balanceOf(claims.orgId);
    return json({ images, creditsCharged: generated * cost, balanceAfter: balance });
  } catch (e) {
    if (e instanceof InsufficientCreditsError) return json({ error: e.message, required: e.required, available: e.available }, 402);
    if (e instanceof ImageError) return error(e.message, e.retryable ? 503 : 402);
    return error("Studio generation failed. Please retry this request.", 500);
  }
}
