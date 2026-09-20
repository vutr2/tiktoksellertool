// Resumable capture drafts. Each angle is immutable and uploaded as binary.
import { createHash, randomUUID } from "node:crypto";
import { inflateSync } from "node:zlib";
import { supabaseAdmin } from "./supabase.ts";
import { assertActiveOrganization } from "./session.ts";
import { isIndustry, type Industry } from "./studio.ts";

export const CUTOUT_BUCKET = "cutouts";
export const MAX_CUTOUT_BYTES = 4 * 1024 * 1024;
const MAX_BASE64_CUTOUT_BYTES = 3 * 1024 * 1024;
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class ProductError extends Error {
  readonly status: number;
  constructor(message: string, status = 400) {
    super(message); this.name = "ProductError"; this.status = status;
  }
}
export interface CreateProductInput {
  productId?: unknown; name?: unknown; category?: unknown; keyFeatures?: unknown;
  cutoutCount?: unknown; cutoutSHA256?: unknown; cutoutPngBase64?: unknown; industry?: unknown;
}
export interface ValidatedProduct {
  productId: string; name: string; category: string | null; keyFeatures: string[];
  cutout: Buffer | null; cutoutSHA256: string[]; staged: boolean; industry: Industry | null;
}
export type Validation = { ok: true; value: ValidatedProduct } | { ok: false; error: string };

export function validateCreateProduct(input: CreateProductInput): Validation {
  if (!input || typeof input !== "object" || Array.isArray(input)) return { ok: false, error: "Enter the product details before continuing." };
  const name = typeof input.name === "string" ? input.name.trim() : "";
  if (!name) return { ok: false, error: "Give the product a name." };
  if (name.length > 200) return { ok: false, error: "Product names are limited to 200 characters." };
  const category = typeof input.category === "string" && input.category.trim() ? input.category.trim() : null;
  if (category && category.length > 300) return { ok: false, error: "Categories are limited to 300 characters." };
  let keyFeatures: string[] = [];
  if (input.keyFeatures !== undefined) {
    if (!Array.isArray(input.keyFeatures)) return { ok: false, error: "Key features must be a list." };
    keyFeatures = input.keyFeatures.filter((f): f is string => typeof f === "string").map((f) => f.trim()).filter(Boolean);
    if (keyFeatures.length > 10) return { ok: false, error: "Keep it to 10 key features." };
    if (keyFeatures.some((f) => f.length > 300)) return { ok: false, error: "Each key feature is limited to 300 characters." };
  }
  if (input.productId !== undefined && (typeof input.productId !== "string" || !UUID.test(input.productId))) return { ok: false, error: "This draft could not be identified. Start a new product." };
  const productId = typeof input.productId === "string" ? input.productId.toLowerCase() : randomUUID();
  const staged = input.cutoutCount !== undefined;
  let cutoutSHA256: string[] = [];
  if (staged) {
    if (input.productId === undefined) return { ok: false, error: "This draft needs an identifier before uploading." };
    if (!Number.isInteger(input.cutoutCount) || Number(input.cutoutCount) < 0 || Number(input.cutoutCount) > 3) return { ok: false, error: "A product can have up to 3 captured angles." };
    if (!Array.isArray(input.cutoutSHA256) || input.cutoutSHA256.length !== input.cutoutCount || input.cutoutSHA256.some((hash) => typeof hash !== "string" || !/^[0-9a-f]{64}$/.test(hash))) return { ok: false, error: "The photo list could not be verified. Retry the same draft." };
    cutoutSHA256 = input.cutoutSHA256 as string[];
    if (input.cutoutPngBase64 != null) return { ok: false, error: "Upload each captured angle separately." };
  }
  let cutout: Buffer | null = null;
  if (input.cutoutPngBase64 != null) {
    if (typeof input.cutoutPngBase64 !== "string") return { ok: false, error: "The cutout must be base64-encoded PNG data." };
    const raw = input.cutoutPngBase64.replace(/^data:image\/png;base64,/, "");
    if (!raw.length) return { ok: false, error: "The cutout is empty." };
    if (raw.length > Math.ceil(MAX_BASE64_CUTOUT_BYTES / 3) * 4) return { ok: false, error: "That image is too large. Upload the photo separately." };
    if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(raw)) return { ok: false, error: "The cutout must be a PNG with transparency, encoded as base64." };
    cutout = Buffer.from(raw, "base64");
    try { validateCutoutPNG(cutout); } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : "The cutout could not be read." };
    }
    cutoutSHA256 = [digest(cutout)];
  }
  const industry = isIndustry(input.industry) ? input.industry : null;
  return { ok: true, value: { productId, name, category, keyFeatures, cutout, cutoutSHA256, staged, industry } };
}

/** Validate chunks and decompression, not just a forgeable 8-byte signature. */
export function validateCutoutPNG(bytes: Buffer): void {
  if (!bytes.length) throw new ProductError("The cutout is empty.");
  if (bytes.length > MAX_CUTOUT_BYTES) throw new ProductError("That image is too large. Retake the photo.", 413);
  const invalid = () => new ProductError("The cutout must be a PNG with transparency and complete image data. Retake the photo.");
  if (!bytes.subarray(0, 8).equals(PNG_MAGIC)) throw invalid();
  let offset = 8, width = 0, height = 0, channels = 0, ended = false;
  const compressed: Buffer[] = [];
  while (offset + 12 <= bytes.length) {
    const length = bytes.readUInt32BE(offset);
    if (length > bytes.length - offset - 12) throw invalid();
    const type = bytes.toString("ascii", offset + 4, offset + 8);
    const chunk = bytes.subarray(offset + 8, offset + 8 + length);
    if (crc32(bytes.subarray(offset + 4, offset + 8 + length)) !== bytes.readUInt32BE(offset + 8 + length)) throw invalid();
    if (offset === 8 && type !== "IHDR") throw invalid();
    if (type === "IHDR") {
      if (offset !== 8 || length !== 13) throw invalid();
      width = chunk.readUInt32BE(0); height = chunk.readUInt32BE(4);
      // Matches UIImage's non-interlaced 8-bit RGBA encoder. The dimension limit
      // also bounds decompressed memory, independent of a small compressed body.
      if (!width || !height || width > 4096 || height > 4096 || chunk[8] !== 8 || ![4, 6].includes(chunk[9]) || chunk[10] !== 0 || chunk[11] !== 0 || chunk[12] !== 0) throw invalid();
      channels = chunk[9] === 6 ? 4 : 2;
    } else if (type === "IDAT") compressed.push(chunk);
    else if (type === "IEND") {
      if (length !== 0 || offset + 12 !== bytes.length) throw invalid();
      ended = true;
    }
    offset += length + 12;
  }
  if (!ended || !compressed.length || offset !== bytes.length) throw invalid();
  const stride = width * channels + 1;
  let pixels: Buffer;
  try { pixels = inflateSync(Buffer.concat(compressed), { maxOutputLength: stride * height }); } catch { throw invalid(); }
  if (pixels.length !== stride * height) throw invalid();
  for (let row = 0; row < height; row++) if (pixels[row * stride] > 4) throw invalid();
}
function crc32(bytes: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function digest(bytes: Buffer | string): string { return createHash("sha256").update(bytes).digest("hex"); }
export function cutoutPath(orgId: string, productId: string, index?: number, hash?: string): string {
  return index === undefined ? `${orgId}/${productId}.png` : `${orgId}/${productId}/${index}-${hash}.png`;
}
export interface CreatedProduct { id: string; name: string; category: string | null; cutoutPath: string | null; createdAt: string }
type ProductRow = { id: string; name: string; category: string | null; cutout_url: string | null; created_at: string; attributes: Record<string, unknown> };
const PRODUCT_COLUMNS = "id, name, category, cutout_url, created_at, attributes";
const dto = (row: ProductRow): CreatedProduct => ({ id: row.id, name: row.name, category: row.category, cutoutPath: row.cutout_url, createdAt: row.created_at });
async function ownedProduct(orgId: string, productId: string): Promise<ProductRow> {
  if (!UUID.test(productId)) throw new ProductError("That product could not be found.", 404);
  const { data, error } = await supabaseAdmin().from("products").select(PRODUCT_COLUMNS).eq("id", productId).eq("org_id", orgId).maybeSingle();
  if (error) throw new ProductError("Could not load this product. Try again.", 500);
  if (!data) throw new ProductError("That product could not be found.", 404);
  return data as ProductRow;
}

export async function createProduct(orgId: string, product: ValidatedProduct): Promise<CreatedProduct> {
  const db = supabaseAdmin();
  await assertActiveOrganization(orgId);
  const creationHash = digest(JSON.stringify([product.name, product.category, product.keyFeatures, product.cutoutSHA256]));
  const { error } = await db.from("products").insert({ id: product.productId, org_id: orgId, name: product.name, category: product.category,
    attributes: { keyFeatures: product.keyFeatures, captureStatus: "uploading", cutoutSHA256: product.cutoutSHA256, creationHash, industry: product.industry } });
  if (error && error.code !== "23505") throw new ProductError("Could not save the product. Retry this draft.", 500);
  const row = await ownedProduct(orgId, product.productId);
  if (row.attributes.creationHash !== creationHash) throw new ProductError("This draft was already saved with different details. Start a new product.", 409);
  if (product.staged) return dto(row);
  if (product.cutout) await uploadProductCutout(orgId, row.id, 0, product.cutout);
  return completeProduct(orgId, row.id);
}

export async function uploadProductCutout(orgId: string, productId: string, index: number, bytes: Buffer): Promise<void> {
  validateCutoutPNG(bytes);
  const row = await ownedProduct(orgId, productId);
  const hashes = row.attributes.cutoutSHA256;
  if (!Array.isArray(hashes) || !Number.isInteger(index) || index < 0 || index >= hashes.length || index >= 3) throw new ProductError("That photo does not belong to this draft.");
  const hash = digest(bytes);
  if (hash !== hashes[index]) throw new ProductError("This photo has changed. Retry with the original draft photo.", 409);
  await assertActiveOrganization(orgId);
  await ensureCutoutBucket();
  const path = cutoutPath(orgId, row.id, index, hash);
  const db = supabaseAdmin();
  const { error } = await db.storage.from(CUTOUT_BUCKET).upload(path, bytes, { contentType: "image/png", upsert: false });
  if (error) {
    const existing = await db.storage.from(CUTOUT_BUCKET).download(path);
    if (existing.error || !existing.data || digest(Buffer.from(await existing.data.arrayBuffer())) !== hash) throw new ProductError("Could not upload that photo. Retry the same draft.", 500);
  }
  try { await assertActiveOrganization(orgId); } catch (error) {
    const cleanup = await db.storage.from(CUTOUT_BUCKET).remove([path]);
    if (cleanup.error) throw new ProductError("Photo cleanup is incomplete. Retry deleting the account.", 500);
    throw error;
  }
}

export async function completeProduct(orgId: string, productId: string): Promise<CreatedProduct> {
  const row = await ownedProduct(orgId, productId);
  if (row.attributes.captureStatus === "ready") return dto(row);
  const hashes = row.attributes.cutoutSHA256;
  if (!Array.isArray(hashes) || hashes.length > 3 || hashes.some((hash) => typeof hash !== "string" || !/^[0-9a-f]{64}$/.test(hash))) throw new ProductError("This product cannot be completed from that draft.", 409);
  const db = supabaseAdmin();
  const paths: string[] = [];
  for (const [index, hash] of hashes.entries()) {
    const path = cutoutPath(orgId, row.id, index, hash as string);
    const { data, error } = await db.storage.from(CUTOUT_BUCKET).download(path);
    if (error || !data) throw new ProductError(`Photo ${index + 1} has not finished uploading. Retry this draft.`, 409);
    const bytes = Buffer.from(await data.arrayBuffer());
    if (digest(bytes) !== hash) throw new ProductError(`Photo ${index + 1} could not be verified. Retry this draft.`, 409);
    validateCutoutPNG(bytes); paths.push(path);
  }
  await assertActiveOrganization(orgId);
  if (paths.length) {
    const assets = paths.map((path, index) => ({ id: imageAssetID(orgId, row.id, index), product_id: row.id,
      type: "image", marketplace: "source", url: path, validation_status: "pending", violations: [] }));
    const { error } = await db.from("assets").upsert(assets, { onConflict: "id", ignoreDuplicates: true });
    if (error) throw new ProductError("Could not save the captured angles. Retry this draft.", 500);
  }
  const { data, error } = await db.from("products").update({ cutout_url: paths[0] ?? null, attributes: { ...row.attributes, captureStatus: "ready" } })
    .eq("id", row.id).eq("org_id", orgId).eq("attributes->>captureStatus", "uploading").select(PRODUCT_COLUMNS).maybeSingle();
  if (error) throw new ProductError("Could not finish saving the product. Retry this draft.", 500);
  if (data) return dto(data as ProductRow);
  // Concurrent identical finalization already won; do not overwrite later attributes.
  const latest = await ownedProduct(orgId, row.id);
  if (latest.attributes.captureStatus !== "ready") throw new ProductError("Could not finish saving the product. Retry this draft.", 500);
  return dto(latest);
}
function imageAssetID(orgId: string, productId: string, index: number): string {
  const bytes = createHash("sha256").update(`listingforge:cutout:${orgId}:${productId}:${index}`).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
export async function ensureCutoutBucket(): Promise<void> {
  const storage = supabaseAdmin().storage;
  const { data } = await storage.getBucket(CUTOUT_BUCKET);
  if (data) { if (data.public) throw new ProductError("Photo storage is not configured as private.", 503); return; }
  const { error } = await storage.createBucket(CUTOUT_BUCKET, { public: false });
  if (error) {
    const existing = await storage.getBucket(CUTOUT_BUCKET);
    if (!existing.data || existing.data.public) throw new ProductError("Photo storage is unavailable. Try again later.", 503);
  }
}
export async function readLimitedBody(request: Request, maximumBytes: number): Promise<Buffer> {
  const reader = request.body?.getReader();
  if (!reader) return Buffer.alloc(0);
  const chunks: Buffer[] = []; let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) return Buffer.concat(chunks, length);
    length += value.byteLength;
    if (length > maximumBytes) { await reader.cancel(); throw new ProductError("That upload is too large. Upload each photo separately.", 413); }
    chunks.push(Buffer.from(value));
  }
}
