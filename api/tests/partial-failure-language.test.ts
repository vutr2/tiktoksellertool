// A partial success is a 200, so its failure reasons never pass through
// error(). They reached the seller in English whatever language they were
// reading the app in.

import { test } from "node:test";
import assert from "node:assert/strict";
import { localizeFailures } from "../src/lib/generate.ts";

const partial = {
  productId: "p1",
  language: "vi" as const,
  assets: [{ type: "title", marketplace: "amazon", content: "Máy pha cà phê", status: "pass", violations: [] }],
  failures: [
    { marketplace: "etsy", reason: "Claude is rate limiting us. Try again shortly." },
    { marketplace: "scripts", reason: "Scripts failed." },
  ],
  creditsCharged: 6,
  balanceAfter: 394,
};

test("failure reasons are translated on the way out", () => {
  const read = localizeFailures(partial, "vi");

  assert.deepEqual(read.failures.map((f) => f.marketplace), ["etsy", "scripts"]);
  for (const failure of read.failures) {
    assert.doesNotMatch(failure.reason, /rate limiting|Scripts failed/);
  }
  assert.match(read.failures[0].reason, /giới hạn/);
});

test("the copy the seller paid for is not touched", () => {
  const read = localizeFailures(partial, "vi");

  assert.deepEqual(read.assets, partial.assets);
  assert.equal(read.creditsCharged, 6);
  assert.equal(read.balanceAfter, 394);
  assert.equal(read.productId, "p1");
});

test("the stored result is left alone, so replay still returns what it stored", () => {
  // Idempotent replay compares and returns the stored row. Translating before
  // storing would change the thing being replayed.
  const before = JSON.stringify(partial);
  localizeFailures(partial, "vi");
  assert.equal(JSON.stringify(partial), before);
});

test("a listing reopened after switching language arrives in the new one", () => {
  // Reasons are stored in English and translated on every read, so this works
  // for results that were generated long before the switch.
  const stored = { failures: [{ marketplace: "etsy", reason: "Generation failed." }] };

  assert.match(localizeFailures(stored, "vi").failures[0].reason, /không thành công/);
  assert.equal(localizeFailures(stored, "en").failures[0].reason, "Generation failed.");
});

test("a result with nothing to translate is passed straight through", () => {
  const clean = { productId: "p1", failures: [] };
  assert.equal(localizeFailures(clean, "vi"), clean);
  assert.equal(localizeFailures(partial, "en"), partial);
});

test("an untranslated reason stays readable rather than becoming blank", () => {
  const stored = { failures: [{ marketplace: "etsy", reason: "Some new provider error." }] };
  assert.equal(localizeFailures(stored, "vi").failures[0].reason, "Some new provider error.");
});
