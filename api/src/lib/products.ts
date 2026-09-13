// Product creation — the step the capture flow hands off to (SPEC §10 step 2).
//
// Validation is a pure function so it can be tested without Supabase. The
// storage and database work sits behind it.

import { supabaseAdmin } from "./supabase.ts";

/** Where cutouts live. Private: URLs are signed per request, never public. */
export const CUTOUT_BUCKET = "cutouts";

/**
 * Cap on the decoded cutout.
 *
 * A 1600px RGBA cutout compresses to well under this, and JSON bodies are size
 * limited on most hosts. TODO(M4): move to a signed direct-to-storage upload so
 * the image never travels through the API at all.
 */
export const MAX_CUTOUT_BYTES = 4 * 1024 * 1024;

const MAX_NAME_LENGTH = 200;
const MAX_FEATURES = 10;
const MAX_FEATURE_LENGTH = 300;

/** PNG signature. The cutout must keep its alpha channel (SPEC §4.1). */
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

export interface CreateProductInput {
  name?: unknown;
  category?: unknown;
  keyFeatures?: unknown;
  cutoutPngBase64?: unknown;
}

export interface ValidatedProduct {
  name: string;
  category: string | null;
  keyFeatures: string[];
  cutout: Buffer | null;
}

export type Validation =
  | { ok: true; value: ValidatedProduct }
  | { ok: false; error: string };

/** Every message here is shown to the seller, so it says what to fix. */
export function validateCreateProduct(input: CreateProductInput): Validation {
  const name = typeof input.name === "string" ? input.name.trim() : "";
  if (!name) return { ok: false, error: "Give the product a name." };
  if (name.length > MAX_NAME_LENGTH) {
    return { ok: false, error: `Product names are limited to ${MAX_NAME_LENGTH} characters.` };
  }

  const category =
    typeof input.category === "string" && input.category.trim() ? input.category.trim() : null;

  let keyFeatures: string[] = [];
  if (input.keyFeatures !== undefined) {
    if (!Array.isArray(input.keyFeatures)) {
      return { ok: false, error: "Key features must be a list." };
    }
    keyFeatures = input.keyFeatures
      .filter((f): f is string => typeof f === "string")
      .map((f) => f.trim())
      .filter(Boolean);
    if (keyFeatures.length > MAX_FEATURES) {
      return { ok: false, error: `Keep it to ${MAX_FEATURES} key features.` };
    }
    if (keyFeatures.some((f) => f.length > MAX_FEATURE_LENGTH)) {
      return { ok: false, error: `Each key feature is limited to ${MAX_FEATURE_LENGTH} characters.` };
    }
  }

  let cutout: Buffer | null = null;
  if (input.cutoutPngBase64 !== undefined && input.cutoutPngBase64 !== null) {
    if (typeof input.cutoutPngBase64 !== "string") {
      return { ok: false, error: "The cutout must be base64-encoded PNG data." };
    }
    // Tolerate a data: URL prefix so the client can send either form.
    const raw = input.cutoutPngBase64.replace(/^data:image\/png;base64,/, "");
    let decoded: Buffer;
    try {
      decoded = Buffer.from(raw, "base64");
    } catch {
      return { ok: false, error: "The cutout could not be read." };
    }
    if (decoded.length === 0) return { ok: false, error: "The cutout is empty." };
    if (decoded.length > MAX_CUTOUT_BYTES) {
      return { ok: false, error: "That image is too large. Retake the photo." };
    }
    // Reject a JPEG or garbage: only a PNG carries the alpha the compositing
    // pipeline depends on.
    if (!decoded.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC)) {
      return { ok: false, error: "The cutout must be a PNG with transparency." };
    }
    cutout = decoded;
  }

  return { ok: true, value: { name, category, keyFeatures, cutout } };
}

/** Storage path for a cutout. Scoped by org so one seller cannot reach another's. */
export function cutoutPath(orgId: string, productId: string): string {
  return `${orgId}/${productId}.png`;
}

export interface CreatedProduct {
  id: string;
  name: string;
  category: string | null;
  cutoutPath: string | null;
  createdAt: string;
}

/**
 * Writes the product row, then the cutout.
 *
 * Row first: a product with no image is recoverable, an orphaned image is not.
 */
export async function createProduct(
  orgId: string,
  product: ValidatedProduct,
): Promise<CreatedProduct> {
  const db = supabaseAdmin();

  const { data, error } = await db
    .from("products")
    .insert({
      org_id: orgId,
      name: product.name,
      category: product.category,
      attributes: { keyFeatures: product.keyFeatures },
    })
    .select("id, name, category, created_at")
    .single();
  if (error) throw new Error(error.message);

  let storedPath: string | null = null;
  if (product.cutout) {
    const path = cutoutPath(orgId, data.id as string);
    const upload = await db.storage
      .from(CUTOUT_BUCKET)
      .upload(path, product.cutout, { contentType: "image/png", upsert: true });
    if (upload.error) throw new Error(upload.error.message);

    storedPath = path;
    const { error: linkError } = await db
      .from("products")
      .update({ cutout_url: path })
      .eq("id", data.id as string);
    if (linkError) throw new Error(linkError.message);
  }

  return {
    id: data.id as string,
    name: data.name as string,
    category: (data.category as string | null) ?? null,
    cutoutPath: storedPath,
    createdAt: data.created_at as string,
  };
}

/** Ensures the private cutout bucket exists. Safe to call repeatedly. */
export async function ensureCutoutBucket(): Promise<void> {
  const db = supabaseAdmin();
  const { data } = await db.storage.getBucket(CUTOUT_BUCKET);
  if (data) return;
  // Private: cutouts are the seller's product photos, not public assets.
  await db.storage.createBucket(CUTOUT_BUCKET, { public: false });
}
