// Content-addressed cache for generated studio images.
//
// Keyed by the actual inputs (cutout bytes + scene + model + variation index),
// so an identical request never pays the provider or waits for a render again —
// even from a different product. Scoped to the org: a generated studio image
// contains the seller's own product, so it must never be served to another org.
//
// The cache lives in the private cutouts bucket under `${orgId}/_studio-cache/`.
// Account deletion already clears everything under the org prefix.

import { createHash } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { supabaseAdmin } from "../supabase.ts";
import { CUTOUT_BUCKET } from "../products.ts";
import { PRESERVE_PRODUCT, type StudioScene } from "../studio.ts";
import { ImageError, type ImageBlob } from "./image.ts";

// Bump when the scene prompts or compositing change so stale images aren't reused.
// v2: switched from Kling redrawing the product to background-only + compositing.
const CACHE_VERSION = "v2";

/** Stable hash of everything that determines the generated pixels. */
export function studioContentHash(input: {
  cutout: Buffer;
  scene: StudioScene;
  index: number;
}): string {
  const model = process.env.KLING_IMAGE_MODEL ?? "kling-v2-1";
  return createHash("sha256")
    .update(JSON.stringify([CACHE_VERSION, model, input.index, input.scene, PRESERVE_PRODUCT]))
    .update(input.cutout)
    .digest("hex");
}

function cachePath(orgId: string, hash: string): string {
  return `${orgId}/_studio-cache/${hash}.png`;
}

/** Returns the cached image for this org + content, or null on a miss. */
export async function readStudioCache(orgId: string, hash: string, db: SupabaseClient = supabaseAdmin()): Promise<ImageBlob | null> {
  const { data, error } = await db.storage.from(CUTOUT_BUCKET).download(cachePath(orgId, hash));
  if (error) {
    // An unavailable cache is not evidence of a miss; avoid paying the
    // provider again merely because storage temporarily failed.
    if ("statusCode" in error && String(error.statusCode) === "404") return null;
    throw new ImageError("Could not check the image cache. Try again later.");
  }
  if (!data) return null;
  return { data: Buffer.from(await data.arrayBuffer()), mime: data.type || "image/png" };
}

/** Stores a freshly generated image so identical future requests reuse it. */
export async function writeStudioCache(orgId: string, hash: string, image: ImageBlob, db: SupabaseClient = supabaseAdmin()): Promise<void> {
  // Best effort: a cache write failure must not fail the generation the user paid for.
  try {
    const { error } = await db.storage.from(CUTOUT_BUCKET)
      .upload(cachePath(orgId, hash), image.data, { contentType: image.mime, upsert: true });
    if (error) console.warn("studio_content_cache_write_failed");
  } catch {
    console.warn("studio_content_cache_write_failed");
  }
}
