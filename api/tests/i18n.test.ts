// Server messages the seller reads, in the language the app asked for.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { languageFromHeader, localize } from "../src/lib/i18n/index.ts";
import { VI } from "../src/lib/i18n/vi.ts";
import { ruleCopy } from "../src/lib/rules/messages.ts";
import { statusOf, validate } from "../src/lib/rules/validate.ts";
import { rulesFor } from "../src/lib/rules/registry.ts";

test("Accept-Language is read, quality values and all", () => {
  assert.equal(languageFromHeader("vi-VN,vi;q=0.9,en;q=0.8"), "vi");
  assert.equal(languageFromHeader("vi"), "vi");
  assert.equal(languageFromHeader("VI-vn"), "vi");
  // Lower quality loses even when it comes first in the header.
  assert.equal(languageFromHeader("vi;q=0.2,en;q=0.9"), "en");
  assert.equal(languageFromHeader("vi;q=0"), "en");
});

test("an unknown or absent language answers in English rather than failing", () => {
  // An error the seller cannot read still beats no answer at all.
  assert.equal(languageFromHeader(null), "en");
  assert.equal(languageFromHeader(""), "en");
  assert.equal(languageFromHeader("fr-FR,de;q=0.9"), "en");
  assert.equal(languageFromHeader("not a header"), "en");
});

test("a translated message comes back in Vietnamese", () => {
  assert.equal(localize("Not authorized.", "vi"), "Bạn chưa được xác thực.");
  assert.equal(localize("Not authorized.", "en"), "Not authorized.");
});

test("messages carrying numbers are matched by shape", () => {
  const vi = localize("This needs 6 credits and you have 0.", "vi");
  assert.match(vi, /6/);
  assert.match(vi, /0/);
  assert.doesNotMatch(vi, /credits/);
});

test("an untranslated message degrades to English, not to a blank or a code", () => {
  // Visibly English in one place beats an empty bubble the seller cannot act on.
  const unknown = "Something nobody has translated yet.";
  assert.equal(localize(unknown, "vi"), unknown);
});

test("a Vietnamese violation has no English left in it", () => {
  const amazon = rulesFor("amazon");
  const long = "x".repeat((amazon.title?.maxChars ?? 200) + 12);
  const violations = validate({ type: "title", text: long }, amazon, "vi");
  const tooLong = violations.find((v) => v.code === "title.too_long");

  assert.ok(tooLong);
  assert.match(tooLong.message, /ký tự/);
  assert.doesNotMatch(tooLong.message, /characters/);
  assert.doesNotMatch(tooLong.detail ?? "", /characters|over/);
  assert.equal(statusOf(violations), "fail");
});

test("every rule message has a Vietnamese builder", () => {
  // The interface is the contract: a message added to RuleCopy without a
  // Vietnamese implementation would not compile, but one that silently returns
  // the English string would. Compare the two tables' output instead.
  const en = ruleCopy("en");
  const vi = ruleCopy("vi");
  const same: string[] = [];
  for (const [name, build] of Object.entries(en) as [string, (...a: never[]) => string][]) {
    const args = [1, 2, 3].slice(0, build.length) as never[];
    if (build(...args) === (vi[name as keyof typeof vi] as typeof build)(...args)) same.push(name);
  }
  // contentLabel deliberately falls through to the raw item name for anything
  // it does not map, which is identical in both tables. Everything else must
  // differ, or it is English wearing a Vietnamese label.
  assert.deepEqual(same.sort(), ["contentLabel"]);
});

function routeFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return routeFiles(path);
    return path.endsWith(".ts") ? [path] : [];
  });
}

test("every seller-facing route message is translated", () => {
  // The failure this catches: a new endpoint answers in English to a seller
  // reading a Vietnamese app.
  const missing: string[] = [];
  for (const file of routeFiles("src/app")) {
    const source = readFileSync(file, "utf8");
    for (const match of source.matchAll(/\b(?:error|tooMany)\(\s*"((?:[^"\\]|\\.)+)"/g)) {
      const message = match[1].replace(/\\"/g, '"');
      if (!VI[message]) missing.push(`${file}: ${message}`);
    }
  }
  assert.deepEqual(missing, [], `untranslated route messages:\n${missing.join("\n")}`);
});
