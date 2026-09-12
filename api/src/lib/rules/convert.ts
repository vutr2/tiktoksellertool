// convert(asset, from, to) — adapt an asset to another marketplace.
//
// SPEC §7: "convert is what people pay for" and "Never silently 'fix' by
// degrading. Always report."
//
// How this stays honest: we do not hand-wave a list of fixes. We build a
// PROJECTED asset by applying only transformations we can actually perform,
// then run validate() against that projection. Whatever still fails is reported
// as unresolved. The engine therefore cannot claim a success it did not
// achieve — the claim is checked by the same rules that judged the original.

import { validate } from "./validate.ts";
import type {
  Asset,
  Change,
  ConversionResult,
  ImageAsset,
  ImageContent,
  ImageFacts,
  MarketplaceRules,
  Violation,
} from "./types";

/**
 * Cost of generating an image, from SPEC §6. Conversion itself is free; only a
 * re-render costs credits.
 *
 * TODO(M5): move to `config/credits.json` served by the API — SPEC §6 wants a
 * single source of truth for costs.
 */
const IMAGE_GENERATION_CREDITS = 5;

export function convert(
  asset: Asset,
  from: MarketplaceRules,
  to: MarketplaceRules,
): ConversionResult {
  const changes: Change[] = [];
  let requiresRerender = false;
  let projected: Asset = asset;

  if (asset.type === "image") {
    const outcome = projectImage(asset, to);
    projected = outcome.asset;
    changes.push(...outcome.changes);
    requiresRerender = outcome.requiresRerender;
  }
  // Text assets are deliberately not transformed. Shortening a title or
  // dropping a bullet loses information the seller wrote on purpose — that is
  // degradation, so it is reported instead of applied.

  // The projection is judged by the same rules as the original.
  const unresolved = validate(projected, to);

  return {
    from: from.id,
    to: to.id,
    changes,
    unresolved,
    requiresRerender,
    creditCost: requiresRerender ? IMAGE_GENERATION_CREDITS : 0,
  };
}

interface ImageProjection {
  asset: ImageAsset;
  changes: Change[];
  requiresRerender: boolean;
}

function projectImage(asset: ImageAsset, to: MarketplaceRules): ImageProjection {
  const changes: Change[] = [];
  let requiresRerender = false;
  const slot = asset.slot;
  const facts: ImageFacts = {
    ...asset.facts,
    contains: asset.facts.contains ? [...asset.facts.contains] : undefined,
  };

  const name = to.displayName;
  const rule = to.images?.[slot];
  if (!rule) return { asset: { ...asset, facts }, changes, requiresRerender };

  // 1. A person in the frame cannot be removed without repainting over the
  //    product, which SPEC §8 forbids. So we do NOT remove them and we do NOT
  //    relocate the image ourselves — which slot holds which shot is the
  //    seller's call, and moving it would decide what becomes the main image.
  //    Instead: recommend the move, and leave the person in `contains` so
  //    re-validation still reports the image as failing. The seller sees an
  //    honest "we could not fix this" next to the offer.
  if (rule.forbid?.includes("human") && facts.contains?.includes("human") && slot === "main") {
    changes.push({
      code: "image.recommend_secondary_slot",
      summary: "A person is still visible",
      detail: `${name} does not allow people on the main image, and removing one would mean painting over the product. Move this shot to a secondary slot, or retake it without hands in frame.`,
      status: "needs_review",
    });
  }

  // 2. Crop to the required aspect ratio. Pixels are discarded, never invented.
  if (rule.aspectRatio) {
    const required = parseRatio(rule.aspectRatio);
    const actual = facts.widthPx / facts.heightPx;
    if (required !== null && Math.abs(actual - required) > (rule.aspectTolerance ?? 0.01)) {
      const before = `${facts.widthPx}×${facts.heightPx}`;
      if (actual > required) {
        facts.widthPx = Math.round(facts.heightPx * required);
      } else {
        facts.heightPx = Math.round(facts.widthPx / required);
      }
      changes.push({
        code: "image.cropped_to_ratio",
        summary: `Cropped to ${rule.aspectRatio}`,
        detail: `${before} → ${facts.widthPx}×${facts.heightPx}, as ${name} requires.`,
        status: "applied",
      });
    }
  }

  // 3. Scale down when the image exceeds the cap. Scaling UP is never done —
  //    inventing pixels is exactly the silent degradation SPEC §7 rules out, so
  //    an image that is too small stays too small and surfaces as unresolved.
  if (rule.maxLongestEdge !== undefined) {
    const longest = Math.max(facts.widthPx, facts.heightPx);
    if (longest > rule.maxLongestEdge) {
      const scale = rule.maxLongestEdge / longest;
      const before = `${facts.widthPx}×${facts.heightPx}`;
      facts.widthPx = Math.round(facts.widthPx * scale);
      facts.heightPx = Math.round(facts.heightPx * scale);
      changes.push({
        code: "image.resized",
        summary: `Resized to ${facts.widthPx} × ${facts.heightPx}`,
        detail: `${before} exceeded the ${rule.maxLongestEdge}px limit.`,
        status: "applied",
      });
    }
  }

  // 4. Crop in to raise how much of the frame the product fills. Fill is an
  //    area share, so the linear crop factor is sqrt(current / target).
  const minFill = rule.productFillRatio?.min;
  if (minFill !== undefined && facts.productFillRatio !== undefined && facts.productFillRatio < minFill) {
    const linear = Math.sqrt(facts.productFillRatio / minFill);
    const before = `${Math.round(facts.productFillRatio * 100)}%`;
    facts.widthPx = Math.round(facts.widthPx * linear);
    facts.heightPx = Math.round(facts.heightPx * linear);
    facts.productFillRatio = minFill;
    changes.push({
      code: "image.cropped_for_fill",
      summary: `Cropped so the product fills ${Math.round(minFill * 100)}% of the frame`,
      detail: `Was ${before}. ${name} expects at least ${Math.round(minFill * 100)}%.`,
      status: "applied",
    });
  }

  // 5. Borders are at the edge of the frame, so they come off with a crop —
  //    no re-render, no cost.
  if (rule.forbid?.includes("border") && facts.contains?.includes("border")) {
    facts.contains = facts.contains.filter((c) => c !== "border");
    changes.push({
      code: "image.border_cropped",
      summary: "Border cropped away",
      detail: `${name} does not allow borders.`,
      status: "applied",
    });
  }

  // 6. Overlay text sits on the background, so re-rendering the background
  //    removes it. The product pixels are untouched (SPEC §8).
  if (rule.forbid?.includes("text") && facts.contains?.includes("text")) {
    facts.contains = facts.contains.filter((c) => c !== "text");
    requiresRerender = true;
    changes.push({
      code: "image.overlay_text_removed",
      summary: "Overlay text removed",
      detail: `Forbidden on the ${slot === "main" ? "main image" : "secondary image"} by ${name}.`,
      status: "applied",
    });
  }

  // 7. Replace the background. The original product pixels are composited onto
  //    the new background — packaging text is never regenerated (SPEC §8).
  if (rule.background?.mustBePureWhite) {
    const expected = rule.background.rgb ?? [255, 255, 255];
    const tolerance = rule.background.tolerance ?? 0;
    const needsWhite =
      !facts.backgroundRGB ||
      !facts.backgroundRGB.every((c, i) => Math.abs(c - expected[i]) <= tolerance);
    if (needsWhite) {
      facts.backgroundRGB = [...expected] as [number, number, number];
      requiresRerender = true;
      changes.push({
        code: "image.background_replaced",
        summary: "Background replaced with pure white",
        detail: `RGB ${expected.join("/")}, as ${name} requires.`,
        status: "applied",
      });
    }
  }

  // Watermarks and logos are left alone on purpose: removing either means
  // painting over content that may be the seller's or someone else's, and we
  // cannot tell which. They fall through to `unresolved`.

  return { asset: { ...asset, facts }, changes, requiresRerender };
}

function parseRatio(ratio: string): number | null {
  const [w, h] = ratio.split(":").map(Number);
  if (!Number.isFinite(w) || !Number.isFinite(h) || h === 0) return null;
  return w / h;
}
