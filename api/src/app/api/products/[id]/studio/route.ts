import { createHash } from "node:crypto";
import { verifySession } from "@/lib/session";
import { managedProduct } from "@/lib/product-management";
import { supabaseAdmin } from "@/lib/supabase";
import { CUTOUT_BUCKET, ProductError, readLimitedBody } from "@/lib/products";
import { isIndustry, findScene, publicCatalog } from "@/lib/studio";
import { composeScene, forgetImageTask, ImageError } from "@/lib/ai/image";
import { SharedStudioWork, TaskCacheFullError } from "@/lib/ai/image-task-cache";
import { studioContentHash, readStudioCache, writeStudioCache } from "@/lib/ai/image-content-cache";
import { billingConfig } from "@/lib/billing-config";
import { assertCanAfford, chargeCredits, balanceOf, InsufficientCreditsError } from "@/lib/credits";
import { json, error } from "@/lib/http";

// One image per request. iOS allows 200s; leave hosting headroom for cleanup.
export const maxDuration = 300;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SIGNED_URL_TTL = 3600;
const activeVariations = new SharedStudioWork<{ path: string; creditsCharged: number }>();

/** Durable result cache key, scoped to the owner, product, scene and variation. */
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

  const { data: rows, error: assetsError } = await db.from("assets").select("id, marketplace, url")
    .eq("product_id", id).like("marketplace", "studio:%");
  if (assetsError) return error("Could not load the saved studio images.", 503);
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

/** Retrieve a saved variation or generate one, keeping a batch out of one HTTP request. */
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
  if (body.index !== undefined && (!Number.isInteger(body.index) || body.index < 0 || body.index > 4)) {
    return error("Choose a valid studio variation.");
  }
  if (body.count !== undefined && ![1, 3, 5].includes(body.count)) return error("Choose 1, 3 or 5 studio shots.");
  // Older builds send only a batch count. They can still request one image,
  // but must update before requesting a batch with a 200-second timeout.
  if ((body.count ?? 3) !== 1) {
    return error("Update Listing Force to generate multiple studio shots, or select 1 angle in this version.", 426);
  }
  const index = (body.index ?? 0) as number;

  const db = supabaseAdmin();
  const { data: product, error: lookupError } = await db.from("products")
    .select("id, cutout_url").eq("id", id).eq("org_id", claims.orgId).maybeSingle();
  if (lookupError) return error("Could not load this product.", 500);
  if (!product) return error("That product could not be found.", 404);
  if (!product.cutout_url) return error("Capture a product photo before generating studio shots.");

  const assertAvailable = async () => {
    const latest = await managedProduct(claims.orgId, id, db);
    if (latest.attributes.captureStatus === "deleting") throw new ProductError("This product is being deleted.", 409);
  };
  const variationKey = `${scene.id}:${index}`;
  const assetId = studioAssetID(claims.orgId, id, variationKey);
  const cost = billingConfig.costs.imageGeneration;
  try {
    await assertAvailable();
    const saved = await activeVariations.run(assetId, async () => {
      // Read inside the shared operation so concurrent retries on this process
      // also join saving/charging, not just the provider generation.
      const { data: existing, error: cacheError } = await db.from("assets").select("url")
        .eq("id", assetId).eq("product_id", id).maybeSingle();
      if (cacheError) throw new ImageError("Could not check saved studio images. Try again later.");
      if (existing?.url) {
        forgetImageTask(assetId);
        return { path: existing.url as string, creditsCharged: 0 };
      }
      const { data: cutout, error: downloadError } = await db.storage.from(CUTOUT_BUCKET).download(product.cutout_url);
      if (downloadError || !cutout) throw new ImageError("The product photo is not available. Retry the capture.");
      const subject = { data: Buffer.from(await cutout.arrayBuffer()), mime: "image/png" };

      const path = `${claims.orgId}/${id}/studio/${scene.id}-${index}.png`;
      const checkSavedProduct = async () => {
        try { await assertAvailable(); }
        catch (e) {
          // Keep retryable uploads during a database outage. Only confirmed
          // deletion permits removing the saved image.
          if (e instanceof ProductError && [404, 409].includes(e.status)) {
            const cleanup = await db.storage.from(CUTOUT_BUCKET).remove([path]);
            if (cleanup.error) throw new ProductError("Photo cleanup is incomplete. Retry deleting the product.", 503);
          }
          throw e;
        }
      };
      const saveAsset = async (image: { data: Buffer; mime: string }) => {
        await assertAvailable();
        const up = await db.storage.from(CUTOUT_BUCKET).upload(path, image.data, { contentType: image.mime, upsert: true });
        if (up.error) throw new ImageError("Could not save the generated image. Retry this style.");
        await checkSavedProduct();
        const { error: insertError } = await db.from("assets").upsert({
          id: assetId, product_id: id, type: "image",
          marketplace: `studio:${variationKey}`, url: path, validation_status: "pass", violations: [],
        }, { onConflict: "id" });
        if (insertError) {
          // A product deleted while its provider request ran must not leave a
          // newly uploaded orphan behind. Other storage errors remain retryable.
          await checkSavedProduct();
          throw new ImageError("Could not save the generated image. Retry this style.");
        }
        await checkSavedProduct();
      };

      // Content cache: identical cutout + scene + variation was already rendered
      // for this org, so reuse it — no provider call, no wait, no charge.
      const contentHash = studioContentHash({ cutout: subject.data, scene, index });
      const cachedImage = await readStudioCache(claims.orgId, contentHash);
      if (cachedImage) {
        await saveAsset(cachedImage);
        forgetImageTask(assetId);
        return { path, creditsCharged: 0 };
      }

      await assertCanAfford(claims.orgId, cost);
      const result = await composeScene(subject, scene, assetId);
      await saveAsset(result);
      // Cross-process reservations and atomic asset/debit settlement still need
      // the migration in docs/STUDIO_ASYNC_PROPOSAL.md. This cache is local only.
      await assertAvailable();
      await chargeCredits(claims.orgId, cost, "generation.image");
      // Publish reusable content only after the original image was charged.
      await writeStudioCache(claims.orgId, contentHash, result);
      forgetImageTask(assetId);
      return { path, creditsCharged: cost };
    });
    const url = await signed(saved.path);
    if (!url) return error("Your image was saved, but its preview is unavailable. Open Studio again to load it.", 503);
    const { balance } = await balanceOf(claims.orgId);
    return json({ images: [{ sceneId: scene.id, index, assetId, url }], creditsCharged: saved.creditsCharged, balanceAfter: balance });
  } catch (e) {
    if (e instanceof ProductError) return error(e.message, e.status);
    if (e instanceof InsufficientCreditsError) return json({ error: e.message, required: e.required, available: e.available }, 402);
    if (e instanceof TaskCacheFullError) return error(e.message, 503);
    if (e instanceof ImageError) {
      // Task IDs and phases help reconcile interrupted paid submissions.
      // Never log the reference image, provider credentials or download URLs.
      console.warn("studio_image_error", {
        phase: e.phase, taskId: e.taskId, submissionUnknown: e.submissionUnknown,
        provider: e.provider, upstreamStatus: e.upstreamStatus, failureReason: e.failureReason,
      });
      // A provider failure is not an insufficient user-credit balance.
      return error(e.message, e.phase === "wait" ? 504 : 503);
    }
    return error("Studio generation failed. Please retry this request.", 500);
  }
}
