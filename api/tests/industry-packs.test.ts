import { test } from "node:test";
import assert from "node:assert/strict";
import { INDUSTRIES } from "../src/lib/studio.ts";
import { INDUSTRY_PACKS, lintClaims } from "../src/lib/industry-packs.ts";

test("every industry has a pack with voice, hashtag guidance and banned claims", () => {
  for (const industry of INDUSTRIES) {
    const pack = INDUSTRY_PACKS[industry];
    assert.ok(pack.voice.length > 0, `${industry} needs a voice`);
    assert.ok(pack.hashtagGuidance.length > 0, `${industry} needs hashtag guidance`);
    assert.ok(pack.bannedClaims.length > 0, `${industry} needs banned claims`);
    for (const claim of pack.bannedClaims) {
      // Every pattern must compile and carry actionable guidance.
      assert.doesNotThrow(() => new RegExp(claim.pattern, "gi"));
      assert.ok(claim.why && claim.fix);
    }
  }
});

test("beauty lint catches medical and absolute claims", () => {
  const hits = lintClaims("This serum cures acne and is 100% safe.", "BEAUTY");
  assert.ok(hits.length >= 2);
  assert.ok(hits.some((h) => /cure/i.test(h.matched)));
  assert.ok(hits.every((h) => h.why && h.fix));
});

test("fashion lint flags a competitor brand name", () => {
  const hits = lintClaims("Looks just like Zara, premium quality.", "FASHION");
  assert.ok(hits.some((h) => /zara/i.test(h.matched)));
});

test("accessories lint flags waterproof", () => {
  const hits = lintClaims("Fully waterproof phone case.", "ACCESSORIES");
  assert.ok(hits.some((h) => /waterproof/i.test(h.matched)));
});

test("clean copy produces no hits", () => {
  assert.deepEqual(lintClaims("Lightweight cotton tee, true to size, machine washable.", "FASHION"), []);
});
