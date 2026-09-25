// A product accumulates assets across generations. One language for the whole
// product mislabels the copy the seller already paid for, and the free rules
// check then reports unchecked Vietnamese copy as clean.

import { test } from "node:test";
import assert from "node:assert/strict";
import { assetLanguages } from "../src/lib/asset-provenance.ts";
import { convert } from "../src/lib/rules/convert.ts";
import { statusOf } from "../src/lib/rules/validate.ts";
import { rulesFor } from "../src/lib/rules/registry.ts";

const amazon = rulesFor("amazon");
const tiktok = rulesFor("tiktok_shop");

/** Newest first, the order the route reads them in. */
const viThenEn = [
  { result: { language: "en", assets: [{ id: "a2" }] } },
  { result: { language: "vi", assets: [{ id: "a1" }] } },
];

test("a Vietnamese asset keeps its language after a later English generation", () => {
  // The reachable case: generate Vietnamese, switch the app to English,
  // generate again for the same product, reopen it from Products.
  const languages = assetLanguages(viThenEn);

  assert.equal(languages.get("a1"), "vi");
  assert.equal(languages.get("a2"), "en");
});

test("the older copy is still judged as Vietnamese through Convert", () => {
  // Same fixture as the review: the earlier asset used to be sent as English
  // and came back pass, hiding that nothing had checked it.
  const languages = assetLanguages(viThenEn);
  const vietnamese = { type: "title" as const, text: "Máy pha cà phê miễn phí vận chuyển" };
  const english = { type: "title" as const, text: "Ceramic pour over coffee dripper" };

  assert.equal(statusOf(convert(vietnamese, tiktok, amazon, { content: languages.get("a1") }).unresolved), "warn");
  assert.equal(statusOf(convert(english, tiktok, amazon, { content: languages.get("a2") }).unresolved), "pass");
});

test("a later request that produced nothing cannot relabel earlier work", () => {
  // A generation can complete with every marketplace failing. It stores a
  // result with no assets, and it is the newest — so under the old rule it
  // decided the language of work it never touched.
  const languages = assetLanguages([
    { result: { language: "en", assets: [], failures: [{ marketplace: "etsy", reason: "x" }] } },
    { result: { language: "vi", assets: [{ id: "a1" }] } },
  ]);

  assert.equal(languages.get("a1"), "vi");
});

test("assets for different marketplaces keep the language of their own run", () => {
  const languages = assetLanguages([
    { result: { language: "en", assets: [{ id: "etsy-title" }, { id: "etsy-desc" }] } },
    { result: { language: "vi", assets: [{ id: "tiktok-title" }, { id: "tiktok-desc" }] } },
  ]);

  assert.deepEqual([...languages.entries()].sort(), [
    ["etsy-desc", "en"], ["etsy-title", "en"],
    ["tiktok-desc", "vi"], ["tiktok-title", "vi"],
  ]);
});

test("results stored before a language was recorded are English", () => {
  // That is what the app could write at the time — a fact about the text, not
  // a guess from whatever the newest request says.
  assert.equal(assetLanguages([{ result: { assets: [{ id: "old" }] } }]).get("old"), "en");
});

test("an asset in no stored result is absent, not English", () => {
  // Unknown origin and English are different answers. Absent lets the caller
  // apply its own documented default instead of being handed a fact we do not
  // have.
  const languages = assetLanguages(viThenEn);
  assert.equal(languages.has("written-by-the-scripts-endpoint"), false);
  assert.equal(languages.get("written-by-the-scripts-endpoint"), undefined);
});

test("malformed history is skipped rather than throwing", () => {
  // The rows come out of a jsonb column; a null or a wrong shape must not take
  // down the listing a seller paid for.
  const languages = assetLanguages([
    { result: null },
    { result: { language: 7, assets: "not an array" } },
    { result: { language: "vi", assets: [null, { id: 5 }, { id: "good" }] } },
  ] as never);

  assert.deepEqual([...languages.entries()], [["good", "vi"]]);
});
