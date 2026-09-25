// Two languages that used to be one parameter.
//
// The content language says what the text is written in, and decides whether
// the engine's English word lists could see it. The interface language only
// decides what the explanation reads like. Conflating them meant a seller who
// switched the app to English saw their Vietnamese copy reported as fully
// checked — the check did not run, and nothing said so.

import { test } from "node:test";
import assert from "node:assert/strict";
import { statusOf, validate } from "../../src/lib/rules/validate.ts";
import { convert } from "../../src/lib/rules/convert.ts";
import { rulesFor } from "../../src/lib/rules/registry.ts";

const amazon = rulesFor("amazon");
const tiktok = rulesFor("tiktok_shop");
const vietnameseTitle = { type: "title" as const, text: "Máy pha cà phê miễn phí vận chuyển" };

test("reading the app in English does not make Vietnamese copy fully checked", () => {
  // The exact regression: same text, same rules, verdict changed with the
  // reader's interface.
  const readingVietnamese = validate(vietnameseTitle, amazon, { content: "vi", messages: "vi" });
  const readingEnglish = validate(vietnameseTitle, amazon, { content: "vi", messages: "en" });

  assert.equal(statusOf(readingVietnamese), "warn");
  assert.equal(statusOf(readingEnglish), "warn");
  assert.deepEqual(
    readingEnglish.map((v) => v.code).sort(),
    readingVietnamese.map((v) => v.code).sort(),
    "the interface language changed which rules fired",
  );
});

test("the interface language changes only the wording", () => {
  const vi = validate(vietnameseTitle, amazon, { content: "vi", messages: "vi" });
  const en = validate(vietnameseTitle, amazon, { content: "vi", messages: "en" });
  const unchecked = (list: typeof vi) => list.find((v) => v.code === "title.promo_language.unchecked");

  assert.match(unchecked(vi)!.message, /quảng cáo/);
  assert.match(unchecked(en)!.message, /promotional wording/);
  assert.equal(unchecked(vi)!.severity, unchecked(en)!.severity);
});

test("an unstated content language means English, which is what old listings are", () => {
  // Every listing saved before the app had a second language really was
  // English. That is a fact about the text, not a guess from the reader.
  assert.equal(statusOf(validate(vietnameseTitle, amazon, {})), "pass");
  assert.equal(statusOf(validate(vietnameseTitle, amazon)), "pass");
});

test("converting a Vietnamese listing does not report it as fully checked", () => {
  // convert() revalidates its projection. It used to do so with the English
  // default whatever the listing was written in.
  const asEnglish = convert(vietnameseTitle, tiktok, amazon);
  const asVietnamese = convert(vietnameseTitle, tiktok, amazon, { content: "vi" });

  assert.equal(statusOf(asEnglish.unresolved), "pass");
  assert.equal(statusOf(asVietnamese.unresolved), "warn");
});

test("what convert says it did is written in the reader's language", () => {
  const image = {
    type: "image" as const,
    slot: "main" as const,
    facts: { widthPx: 2000, heightPx: 1000, contains: ["border" as const] },
  };
  const vi = convert(image, tiktok, amazon, { content: "vi", messages: "vi" });
  const en = convert(image, tiktok, amazon, { content: "vi", messages: "en" });

  assert.ok(vi.changes.length > 0, "expected the projection to change something");
  assert.equal(vi.changes.length, en.changes.length);
  for (const [index, change] of vi.changes.entries()) {
    assert.equal(change.code, en.changes[index].code);
    assert.notEqual(change.summary, en.changes[index].summary,
                    `"${change.summary}" is identical in both languages`);
  }
});
