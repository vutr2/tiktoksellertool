import { test } from "node:test";
import assert from "node:assert/strict";
import { rulesFor } from "../../src/lib/rules/registry.ts";
import { statusOf, validate } from "../../src/lib/rules/validate.ts";
import type { ImageAsset, Violation } from "../../src/lib/rules/types.ts";

const amazon = rulesFor("amazon");
const tiktok = rulesFor("tiktok_shop");

const codes = (violations: Violation[]) => violations.map((v) => v.code).sort();

/** A shot that satisfies every Amazon main-image rule. */
function compliantAmazonMain(): ImageAsset {
  return {
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
}

test("a compliant main image produces no violations", () => {
  assert.deepEqual(validate(compliantAmazonMain(), amazon), []);
  assert.equal(statusOf([]), "pass");
});

test("every violation is reported, not just the first", () => {
  // SPEC §7 comments the signature "Every violation, not just the first." A
  // seller handed one problem at a time needs one round trip per problem.
  const broken: ImageAsset = {
    type: "image",
    slot: "main",
    facts: {
      widthPx: 1000,
      heightPx: 800,
      backgroundRGB: [230, 221, 209],
      productFillRatio: 0.4,
      contains: ["text", "human", "watermark"],
    },
  };

  const violations = validate(broken, amazon);

  assert.deepEqual(codes(violations), [
    "image.aspect_ratio",
    "image.background.not_white",
    "image.content.human",
    "image.content.text",
    "image.content.watermark",
    "image.fill.too_small",
    "image.too_small",
  ]);
  assert.equal(statusOf(violations), "fail");
});

test("one photo, four sets of rules — the same shot passes TikTok and fails Amazon", () => {
  const lifestyle: ImageAsset = {
    type: "image",
    slot: "main",
    facts: {
      widthPx: 2000,
      heightPx: 2000,
      backgroundRGB: [230, 221, 209],
      productFillRatio: 0.6,
      contains: ["text"],
    },
  };

  // TikTok Shop allows overlay text on a lifestyle main image.
  assert.deepEqual(validate(lifestyle, tiktok), []);

  assert.deepEqual(codes(validate(lifestyle, amazon)), [
    "image.background.not_white",
    "image.content.text",
    "image.fill.too_small",
  ]);
});

test("an unanalysed image warns instead of quietly passing", () => {
  // `contains: undefined` means nobody has looked at the image yet. Treating
  // that as "clean" would be the silent pass SPEC §7 rules out.
  const unanalysed: ImageAsset = {
    type: "image",
    slot: "main",
    facts: { widthPx: 2000, heightPx: 2000, backgroundRGB: [255, 255, 255], productFillRatio: 0.9 },
  };

  const violations = validate(unanalysed, amazon);

  assert.deepEqual(codes(violations), ["image.content.unknown"]);
  assert.equal(violations[0].severity, "warn");
  assert.equal(statusOf(violations), "warn");
});

test("an empty contains array means analysed and clean, unlike undefined", () => {
  const analysed = compliantAmazonMain();
  assert.deepEqual(validate(analysed, amazon), []);
});

test("an unmeasured background warns rather than failing", () => {
  const asset: ImageAsset = {
    type: "image",
    slot: "main",
    facts: { widthPx: 2000, heightPx: 2000, productFillRatio: 0.9, contains: [] },
  };

  const violations = validate(asset, amazon);
  assert.deepEqual(codes(violations), ["image.background.unknown"]);
  assert.equal(violations[0].severity, "warn");
});

test("background tolerance accepts near-white but rejects visibly off-white", () => {
  const nearWhite = compliantAmazonMain();
  nearWhite.facts.backgroundRGB = [254, 255, 254]; // within tolerance 2
  assert.deepEqual(validate(nearWhite, amazon), []);

  const offWhite = compliantAmazonMain();
  offWhite.facts.backgroundRGB = [248, 248, 248];
  assert.deepEqual(codes(validate(offWhite, amazon)), ["image.background.not_white"]);
});

test("violation messages are plain English with no codes or field paths", () => {
  const broken: ImageAsset = {
    type: "image",
    slot: "main",
    facts: {
      widthPx: 800,
      heightPx: 800,
      backgroundRGB: [0, 0, 0],
      productFillRatio: 0.2,
      contains: ["text"],
    },
  };

  for (const violation of validate(broken, amazon)) {
    // SPEC §10: "the rule named in plain English".
    assert.ok(violation.message.length > 0);
    // Sentences, not identifiers: ends in a full stop, carries no snake_case
    // code and no dotted field path.
    assert.match(violation.message, /[.!?]$/, `not a sentence: ${violation.message}`);
    assert.ok(!violation.message.includes("_"), `snake_case leaked: ${violation.message}`);
    assert.ok(!violation.message.includes(violation.code), `code leaked: ${violation.message}`);
    assert.ok(!violation.message.includes("images."), `field path leaked: ${violation.message}`);
    assert.ok(violation.message.includes("Amazon"), `message should name the marketplace: ${violation.message}`);
  }
});

// ── Titles ───────────────────────────────────────────────────────────────────

test("a title over the cap fails and reports how far over", () => {
  const violations = validate({ type: "title", text: "x".repeat(215) }, amazon);
  assert.deepEqual(codes(violations), ["title.too_long"]);
  assert.match(violations[0].detail!, /215 characters/);
  assert.match(violations[0].detail!, /15 over/);
});

test("a title at exactly the cap passes", () => {
  assert.deepEqual(validate({ type: "title", text: "x".repeat(200) }, amazon), []);
});

test("all-caps titles fail, but short acronyms do not trip it", () => {
  assert.deepEqual(
    codes(validate({ type: "title", text: "CERAMIC POUR OVER COFFEE DRIPPER" }, amazon)),
    ["title.all_caps"],
  );
  // "USB C" is 4 letters — below the threshold, and a normal title survives.
  assert.deepEqual(validate({ type: "title", text: "USB C ceramic dripper" }, amazon), []);
});

test("promotional wording warns rather than blocking", () => {
  const violations = validate(
    { type: "title", text: "Ceramic pour-over dripper — best price, free shipping" },
    amazon,
  );
  assert.deepEqual(codes(violations), ["title.promo_language"]);
  assert.equal(violations[0].severity, "warn");
  assert.equal(statusOf(violations), "warn");
});

test("marketplaces with no title rule yet accept anything", () => {
  // TikTok Shop's title limits are not modelled — claiming a pass or a fail
  // would both be inventions.
  assert.deepEqual(validate({ type: "title", text: "x".repeat(5000) }, tiktok), []);
});

// ── Descriptions ─────────────────────────────────────────────────────────────

test("too many bullets fails with the actual count", () => {
  const violations = validate(
    { type: "description", bullets: ["a", "b", "c", "d", "e", "f"] },
    amazon,
  );
  assert.deepEqual(codes(violations), ["description.too_many_bullets"]);
  assert.match(violations[0].detail!, /has 6/);
});

test("each over-long bullet is reported separately, by position", () => {
  const violations = validate(
    { type: "description", bullets: ["fine", "x".repeat(600), "fine", "y".repeat(700)] },
    amazon,
  );
  assert.equal(violations.length, 2);
  assert.match(violations[0].detail!, /Bullet 2/);
  assert.match(violations[1].detail!, /Bullet 4/);
});

test("a paragraph description fails where bullets are required", () => {
  const violations = validate({ type: "description", text: "One long paragraph." }, amazon);
  assert.deepEqual(codes(violations), ["description.wrong_format"]);
});

test("statusOf ranks fail above warn above pass", () => {
  const warn: Violation = { code: "w", severity: "warn", field: "f", message: "m" };
  const fail: Violation = { code: "f", severity: "fail", field: "f", message: "m" };
  assert.equal(statusOf([]), "pass");
  assert.equal(statusOf([warn]), "warn");
  assert.equal(statusOf([warn, fail]), "fail");
});
