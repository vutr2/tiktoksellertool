import type { SupabaseClient } from "@supabase/supabase-js";
import { supabaseAdmin } from "./supabase.ts";
import { CUTOUT_BUCKET, ProductError } from "./products.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function managedProduct(orgId: string, id: string, db: SupabaseClient = supabaseAdmin()) {
  if (!UUID.test(id)) throw new ProductError("That product could not be found.", 404);
  const { data, error } = await db.from("products").select("id, cutout_url, attributes")
    .eq("id", id).eq("org_id", orgId).maybeSingle();
  if (error) throw new ProductError("Could not load the product. Try again.", 503);
  if (!data) throw new ProductError("That product could not be found.", 404);
  return data as { id: string; cutout_url: string | null; attributes: Record<string, unknown> };
}

/** CAS protects capture metadata and another device's simultaneous changes. */
export async function setProductHidden(orgId: string, id: string, hidden: boolean, db = supabaseAdmin()) {
  for (let attempt = 0; attempt < 3; attempt++) {
    const product = await managedProduct(orgId, id, db);
    if (product.attributes.captureStatus === "deleting") throw new ProductError("Finish deleting this product first.", 409);
    const { data, error } = await db.from("products")
      .update({ attributes: { ...product.attributes, hidden } }).eq("id", id).eq("org_id", orgId)
      .eq("attributes", JSON.stringify(product.attributes)).select("id").maybeSingle();
    if (error) throw new ProductError("Could not update this product. Try again.", 503);
    if (data) return;
  }
  throw new ProductError("This product changed on another device. Refresh and try again.", 409);
}

export function ownsProductPhoto(orgId: string, id: string, path: string): boolean {
  return !path.split("/").some(part => !part || part === "." || part === "..") &&
    (path === `${orgId}/${id}.png` || path.startsWith(`${orgId}/${id}/`));
}

/** Mark first, clean storage second, delete the row last. A failed cleanup is
 * visible in Products and retryable; no success is reported for partial work. */
export async function deleteProduct(orgId: string, id: string, db = supabaseAdmin()) {
  let product;
  try { product = await managedProduct(orgId, id, db); }
  catch (error) { if (error instanceof ProductError && error.status === 404) return; throw error; }
  const { data: running, error: runningError } = await db.from("generation_requests").select("id")
    .eq("org_id", orgId).eq("product_id", id).eq("status", "running")
    .gt("lease_expires_at", new Date().toISOString()).limit(1);
  if (runningError) throw new ProductError("Could not check pending generation. Try again.", 503);
  if (running?.length) throw new ProductError("This product is generating a listing. Wait until it finishes before deleting it.", 409);
  if (product.attributes.captureStatus !== "deleting") {
    const { data, error } = await db.from("products")
      .update({ attributes: { ...product.attributes, captureStatus: "deleting" } })
      .eq("id", id).eq("org_id", orgId).eq("attributes", JSON.stringify(product.attributes))
      .select("id").maybeSingle();
    if (error) throw new ProductError("Could not start deleting this product. Try again.", 503);
    if (!data) throw new ProductError("This product changed. Refresh and try deleting again.", 409);
  }
  const bucket = db.storage.from(CUTOUT_BUCKET);
  const { error: bucketError } = await db.storage.getBucket(CUTOUT_BUCKET);
  if (bucketError && bucketError.message !== "Bucket not found" && String(bucketError.status) !== "404") {
    throw new ProductError("Could not check saved photos. Retry deleting this product.", 503);
  }
  if (!bucketError) {
    const paths: string[] = [];
    async function collect(prefix: string) {
      let offset = 0;
      while (true) {
        const { data, error } = await bucket.list(prefix, { limit: 1000, offset, sortBy: { column: "name", order: "asc" } });
        if (error || !data) throw new ProductError("Could not list saved photos. Retry deleting this product.", 503);
        for (const item of data) {
          if (!item.name || [".", ".."].includes(item.name) || item.name.includes("/")) throw new ProductError("Could not verify a photo path.", 503);
          const path = `${prefix}/${item.name}`;
          if (!ownsProductPhoto(orgId, id, path)) throw new ProductError("Could not verify a photo path.", 503);
          if (item.id === null) await collect(path); else paths.push(path);
        }
        if (data.length < 1000) break;
        offset += data.length;
      }
    }
    await collect(`${orgId}/${id}`);
    // Legacy captures used a flat path; do not delete any other product's path.
    if (product.cutout_url && ownsProductPhoto(orgId, id, product.cutout_url)) paths.push(product.cutout_url);
    const unique = [...new Set(paths)];
    for (let offset = 0; offset < unique.length; offset += 100) {
      const { error } = await bucket.remove(unique.slice(offset, offset + 100));
      if (error) throw new ProductError("Some photos could not be deleted. Retry deleting this product.", 503);
    }
  }
  const { error } = await db.from("products").delete().eq("id", id).eq("org_id", orgId);
  if (error) throw new ProductError("Could not finish deleting this product. Try again.", 503);
}
