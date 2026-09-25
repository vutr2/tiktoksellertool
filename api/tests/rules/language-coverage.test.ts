// The engine's word lists are English. These tests pin what it does when the
// text is not — SPEC §7: never let "not checked" read as "clean".

import { test } from "node:test";
import assert from "node:assert/strict";
import { statusOf, validate } from "../../src/lib/rules/validate.ts";
import { rulesFor } from "../../src/lib/rules/registry.ts";

// Amazon is the marketplace that forbids promotional wording in a title.
const amazon = rulesFor("amazon");

test("a Vietnamese title says out loud that promotional wording was not checked", () => {
  const violations = validate({ type: "title", text: "Máy pha cà phê pour-over bằng sứ" }, amazon, "vi");
  const unchecked = violations.find((v) => v.code === "title.promo_language.unchecked");
  assert.ok(unchecked, "expected an unchecked warning");
  assert.equal(unchecked.severity, "warn");
  // Shown to the seller verbatim, so no codes and no field paths.
  assert.doesNotMatch(unchecked.message, /[_.]\w+\b|title\./);
  // A warning must not read as a pass.
  assert.equal(statusOf(violations), "warn");
});

test("the same title in English is not warned about", () => {
  const violations = validate({ type: "title", text: "Ceramic pour-over coffee dripper" }, amazon);
  assert.equal(violations.filter((v) => v.code.endsWith(".unchecked")).length, 0);
});

test("English promotional wording is still caught inside Vietnamese copy", () => {
  // Sellers paste "free shipping" into any language; finding it beats warning
  // that nothing was looked at.
  const violations = validate({ type: "title", text: "Máy pha cà phê free shipping" }, amazon, "vi");
  assert.ok(violations.some((v) => v.code === "title.promo_language"));
  assert.equal(violations.filter((v) => v.code === "title.promo_language.unchecked").length, 0);
});

test("character limits count the composed form, so accents do not fail a title", () => {
  const composed = "Máy pha cà phê".normalize("NFC");
  const decomposed = composed.normalize("NFD");
  assert.notEqual(composed.length, decomposed.length, "test needs the two forms to differ");

  const rules = { ...amazon, title: { ...amazon.title, maxChars: composed.length } };
  for (const text of [composed, decomposed]) {
    const tooLong = validate({ type: "title", text }, rules, "vi").filter((v) => v.code === "title.too_long");
    assert.deepEqual(tooLong, [], "the same title must not fail on its accent encoding alone");
  }
});

test("a bullet is measured on its composed form too", () => {
  const bullet = "Giữ nhiệt lâu".normalize("NFC");
  const rules = {
    ...amazon,
    description: { ...amazon.description, format: "bullets" as const, maxCharsPerBullet: bullet.length },
  };
  const violations = validate(
    { type: "description", bullets: [bullet.normalize("NFD")] },
    rules,
    "vi",
  );
  assert.equal(violations.filter((v) => v.code === "description.bullet_too_long").length, 0);
});
