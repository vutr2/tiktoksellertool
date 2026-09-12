import { test } from "node:test";
import assert from "node:assert/strict";
import { rulesFor } from "../../src/lib/rules/registry.ts";
import { convert } from "../../src/lib/rules/convert.ts";
import type { ImageAsset } from "../../src/lib/rules/types.ts";

const amazon = rulesFor("amazon");
const tiktok = rulesFor("tiktok_shop");

const changeCodes = (r: { changes: { code: string }[] }) => r.changes.map((c) => c.code).sort();
const unresolvedCodes = (r: { unresolved: { code: string }[] }) => r.unresolved.map((v) => v.code).sort();

test("the canonical case from SPEC §7 and the Figma design", () => {
  // "a lifestyle image that works as a TikTok Shop main image contains overlay
  // text and a human hand — both forbidden on an Amazon main image."
  const lifestyle: ImageAsset = {
    type: "image",
    slot: "main",
    facts: {
      widthPx: 2000,
      heightPx: 2000,
      backgroundRGB: [230, 221, 209],
      productFillRatio: 0.6,
      contains: ["text", "human"],
    },
  };

  const result = convert(lifestyle, tiktok, amazon);

  // The design's "What changed" list: three green rows and one orange.
  assert.deepEqual(changeCodes(result), [
    "image.background_replaced",
    "image.cropped_for_fill",
    "image.overlay_text_removed",
    "image.recommend_secondary_slot",
  ]);

  const applied = result.changes.filter((c) => c.status === "applied");
  const review = result.changes.filter((c) => c.status === "needs_review");
  assert.equal(applied.length, 3);
  assert.equal(review.length, 1);
  assert.equal(review[0].code, "image.recommend_secondary_slot");

  // The hand could not be removed, so it is still reported as failing. The
  // engine offers the move; it does not pretend the problem is gone.
  assert.deepEqual(unresolvedCodes(result), ["image.content.human"]);

  // Re-rendering the background costs credits (SPEC §6: image generation = 5).
  assert.equal(result.requiresRerender, true);
  assert.equal(result.creditCost, 5);
  assert.equal(result.from, "tiktok_shop");
  assert.equal(result.to, "amazon");
});

test("a conversion needing no re-render is free — the hook in SPEC §6", () => {
  const wideButClean: ImageAsset = {
    type: "image",
    slot: "main",
    facts: {
      widthPx: 2000,
      heightPx: 1600,
      backgroundRGB: [255, 255, 255],
      productFillRatio: 0.9,
      contains: [],
    },
  };

  const result = convert(wideButClean, tiktok, amazon);

  assert.deepEqual(changeCodes(result), ["image.cropped_to_ratio"]);
  assert.deepEqual(result.unresolved, []);
  assert.equal(result.requiresRerender, false);
  assert.equal(result.creditCost, 0, "cropping costs nothing");
});

test("an image that is too small is never upscaled to fake compliance", () => {
  const small: ImageAsset = {
    type: "image",
    slot: "main",
    facts: {
      widthPx: 1200,
      heightPx: 1200,
      backgroundRGB: [255, 255, 255],
      productFillRatio: 0.9,
      contains: [],
    },
  };

  const result = convert(small, tiktok, amazon);

  // Inventing pixels would be exactly the silent degradation SPEC §7 forbids.
  assert.deepEqual(result.changes, []);
  assert.deepEqual(unresolvedCodes(result), ["image.too_small"]);
  assert.equal(result.creditCost, 0);
});

test("watermarks are left alone rather than painted over", () => {
  const watermarked: ImageAsset = {
    type: "image",
    slot: "main",
    facts: {
      widthPx: 2000,
      heightPx: 2000,
      backgroundRGB: [255, 255, 255],
      productFillRatio: 0.9,
      contains: ["watermark"],
    },
  };

  const result = convert(watermarked, tiktok, amazon);

  assert.deepEqual(result.changes, [], "nothing should claim to have removed it");
  assert.deepEqual(unresolvedCodes(result), ["image.content.watermark"]);
});

test("a border is cropped away without a re-render", () => {
  const bordered: ImageAsset = {
    type: "image",
    slot: "main",
    facts: {
      widthPx: 2000,
      heightPx: 2000,
      backgroundRGB: [255, 255, 255],
      productFillRatio: 0.9,
      contains: ["border"],
    },
  };

  const result = convert(bordered, tiktok, amazon);

  assert.deepEqual(changeCodes(result), ["image.border_cropped"]);
  assert.deepEqual(result.unresolved, []);
  assert.equal(result.creditCost, 0);
});

test("an over-long title is reported, never truncated", () => {
  const result = convert({ type: "title", text: "x".repeat(260) }, tiktok, amazon);

  // Cutting 60 characters off a title the seller wrote is degradation.
  assert.deepEqual(result.changes, []);
  assert.deepEqual(unresolvedCodes(result), ["title.too_long"]);
  assert.equal(result.creditCost, 0);
});

test("changes and unresolved never contradict each other", () => {
  const messy: ImageAsset = {
    type: "image",
    slot: "main",
    facts: {
      widthPx: 3000,
      heightPx: 2400,
      backgroundRGB: [12, 12, 12],
      productFillRatio: 0.5,
      contains: ["text", "border"],
    },
  };

  const result = convert(messy, tiktok, amazon);

  // Whatever the changes claim to have fixed must not reappear as unresolved —
  // guaranteed by construction, since unresolved comes from re-validating the
  // projected asset rather than from a hand-written list.
  const claimed = new Set(changeCodes(result));
  if (claimed.has("image.background_replaced")) {
    assert.ok(!unresolvedCodes(result).includes("image.background.not_white"));
  }
  if (claimed.has("image.overlay_text_removed")) {
    assert.ok(!unresolvedCodes(result).includes("image.content.text"));
  }
  if (claimed.has("image.border_cropped")) {
    assert.ok(!unresolvedCodes(result).includes("image.content.border"));
  }
  assert.deepEqual(result.unresolved, [], "everything here is mechanically fixable");
});

test("converting to a marketplace with looser rules is a no-op", () => {
  const amazonReady: ImageAsset = {
    type: "image",
    slot: "main",
    facts: {
      widthPx: 2000,
      heightPx: 2000,
      backgroundRGB: [255, 255, 255],
      productFillRatio: 0.9,
      contains: [],
    },
  };

  const result = convert(amazonReady, amazon, tiktok);

  assert.deepEqual(result.changes, []);
  assert.deepEqual(result.unresolved, []);
  assert.equal(result.creditCost, 0);
});

test("every change carries a human summary and detail", () => {
  const lifestyle: ImageAsset = {
    type: "image",
    slot: "main",
    facts: {
      widthPx: 2000, heightPx: 2000,
      backgroundRGB: [230, 221, 209], productFillRatio: 0.6,
      contains: ["text", "human"],
    },
  };

  for (const change of convert(lifestyle, tiktok, amazon).changes) {
    assert.ok(change.summary.length > 0, `${change.code} has no summary`);
    assert.ok(change.detail.length > 0, `${change.code} has no detail`);
    assert.ok(!change.summary.includes("_"), `snake_case leaked: ${change.summary}`);
  }
});
