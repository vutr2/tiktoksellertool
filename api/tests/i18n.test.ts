// Server messages the seller reads, in the language the app asked for.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import ts from "typescript";
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
  for (const key of ["constructor", "toString", "__proto__"]) {
    assert.equal(localize(key, "vi"), key, "dictionary prototypes are not translations");
  }
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

function sourceFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return sourceFiles(path);
    return path.endsWith(".ts") ? [path] : [];
  });
}

// Syntax rather than regex covers quotes, ternary fallbacks, templates and
// concatenation. This is not data-flow analysis of arbitrary upstream errors.
function messageForms(node: ts.Expression): string[] {
  if (ts.isStringLiteralLike(node)) return [node.text];
  if (ts.isParenthesizedExpression(node)) return messageForms(node.expression);
  if (ts.isTemplateExpression(node)) return [node.head.text + node.templateSpans.map(span => "{value}" + span.literal.text).join("")];
  if (ts.isConditionalExpression(node)) return [...messageForms(node.whenTrue), ...messageForms(node.whenFalse)];
  if (ts.isBinaryExpression(node)) {
    const left = messageForms(node.left), right = messageForms(node.right);
    if (node.operatorToken.kind === ts.SyntaxKind.PlusToken) return left.flatMap(a => right.map(b => a + b));
    if ([ts.SyntaxKind.QuestionQuestionToken, ts.SyntaxKind.BarBarToken].includes(node.operatorToken.kind)) return [...left, ...right];
  }
  return [];
}

function messagesIn(file: string, text: string): string[] {
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true);
  const messages: string[] = [];
  function visit(node: ts.Node) {
    let argument: ts.Expression | undefined;
    if (ts.isNewExpression(node) && /Error$/.test(node.expression.getText(source))) {
      argument = node.arguments?.[node.expression.getText(source) === "ProviderError" ? 1 : 0];
    } else if (ts.isCallExpression(node)) {
      const callee = node.expression.getText(source);
      if (["error", "tooMany", "super"].includes(callee)) argument = node.arguments[0];
      if (callee === "checked" && file.endsWith("/account-deletion.ts")) argument = node.arguments[1];
    } else if (ts.isPropertyAssignment(node) && ["error", "reason"].includes(node.name.getText(source))) {
      argument = node.initializer;
    }
    if (argument) messages.push(...messageForms(argument));
    ts.forEachChild(node, visit);
  }
  visit(source);
  return messages;
}

// Exact file/message exemptions with reasons, never whole directories.
const INTERNAL: Record<string, string> = {
  "src/lib/supabase.ts: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set.": "Server configuration",
  "src/lib/session.ts: SESSION_SECRET must be set.": "Server configuration",
  "src/lib/env.ts: {value} must be set.": "Server configuration",
  "src/lib/apple.ts: {value} must be configured for Apple account deletion.": "Wrapped by seller-facing Apple revocation failure",
  "src/lib/email.ts: Email provider rejected the request ({value}). {value}": "Wrapped by verification email failure",
  "src/lib/credits.ts: Credit deltas must be whole credits.": "Internal ledger invariant",
  "src/lib/credits.ts: A zero-credit entry records nothing.": "Internal ledger invariant",
};

// Changed/new templates fail until their translator and examples are present.
const DYNAMIC: Record<string, string[]> = {
  "This needs {value} credits and you have {value}.": ["This needs 6 credits and you have 0.", "This needs 12 credits and you have -2."],
  "Claude returned an error ({value}).": ["Claude returned an error (503).", "Claude returned an error (no status)."],
  "Photo {value} has not finished uploading. Retry this draft.": ["Photo 1 has not finished uploading. Retry this draft."],
  "Photo {value} could not be verified. Retry this draft.": ["Photo 3 could not be verified. Retry this draft."],
  "Unknown marketplace: {value}": ["Unknown marketplace: unsupported"],
  "Could not download the generated image ({value}).": ["Could not download the generated image (503)."],
  "Image service error ({value}).": ["Image service error (400)."],
  "Image service error ({value}/{value}).": ["Image service error (400/1102)."],
  "Image service error ({value}/{value}). Submission needs checking before retrying.": ["Image service error (503/unknown). Submission needs checking before retrying."],
  "Image service {value} {value}. Submission needs checking before retrying.": [
    "Image service submit took too long. Submission needs checking before retrying.",
    "Image service submit could not connect. Submission needs checking before retrying.",
  ],
  "Image service {value} {value}. Check the existing task again.": [
    "Image service status took too long. Check the existing task again.",
    "Image service download could not connect. Check the existing task again.",
  ],
};

test("seller-facing route and library message forms have Vietnamese translations", () => {
  const missing: string[] = [];
  const exemptions = new Set<string>();
  const dynamic = new Set<string>();
  for (const file of [...sourceFiles("src/app"), ...sourceFiles("src/lib")]) {
    for (const message of messagesIn(file, readFileSync(file, "utf8"))) {
      const key = `${file}: ${message}`;
      if (INTERNAL[key]) { exemptions.add(key); continue; }
      if (message.includes("{value}")) {
        const examples = DYNAMIC[message];
        if (!examples?.length) { missing.push(key); continue; }
        dynamic.add(message);
        for (const example of examples) if (localize(example, "vi") === example) missing.push(`${file}: ${example}`);
      } else if (!VI[message] || localize(message, "vi") === message) missing.push(key);
    }
  }
  assert.deepEqual(missing, [], `untranslated messages:\n${missing.join("\n")}`);
  assert.deepEqual([...exemptions].sort(), Object.keys(INTERNAL).sort(), "remove stale exemptions");
  assert.deepEqual([...dynamic].sort(), Object.keys(DYNAMIC).sort(), "remove stale template examples");
});
