import { test } from "node:test";
import assert from "node:assert/strict";
import { languageRule } from "../../src/lib/ai/anthropic.ts";
import { immutableInputOf, quoteCredits } from "../../src/lib/generate.ts";

test("English adds nothing to the prompt", () => {
  // The English prompt is the one every existing trace was produced under.
  // Appending "write in English" would change it for no benefit.
  assert.equal(languageRule("en"), "");
  assert.equal(languageRule(undefined), "");
});

test("Vietnamese names the language and protects text taken from the product", () => {
  const rule = languageRule("vi");
  assert.match(rule, /Vietnamese/);
  // A translated label no longer matches what is in the box, and the JSON keys
  // are the contract the parser reads.
  assert.match(rule, /do not translate/i);
  assert.match(rule, /JSON keys in English/);
});

test("the idempotency key is unchanged for English, so in-flight requests keep their hash", () => {
  const base = { productId: "p", marketplaces: ["amazon" as const], scriptCount: 2 };
  const before = immutableInputOf(base);
  assert.deepEqual(before, { marketplaces: ["amazon"], scriptCount: 2 });
  assert.equal(JSON.stringify(immutableInputOf({ ...base, language: "en" })), JSON.stringify(before));
});

test("Vietnamese is a different piece of work from English", () => {
  // Without this, replaying a completed request would return the other
  // language's cached result and begin_generation would not see a conflict.
  const base = { productId: "p", marketplaces: ["amazon" as const], scriptCount: 0 };
  assert.notEqual(
    JSON.stringify(immutableInputOf({ ...base, language: "vi" })),
    JSON.stringify(immutableInputOf({ ...base, language: "en" })),
  );
});

test("language does not change the price", () => {
  const base = { productId: "p", marketplaces: ["amazon" as const, "tiktok_shop" as const], scriptCount: 3 };
  assert.equal(quoteCredits({ ...base, language: "vi" }), quoteCredits(base));
});
