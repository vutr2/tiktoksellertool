import { test } from "node:test";
import assert from "node:assert/strict";
import { parseAdScripts, parseProductFacts, stripFence } from "../../src/lib/ai/anthropic.ts";
import { ProviderError } from "../../src/lib/ai/types.ts";

test("a code fence is stripped even though the prompt forbids one", () => {
  // Models add fences anyway; a parser that trusts the instruction breaks in
  // production and nowhere else.
  assert.equal(stripFence('```json\n{"a":1}\n```'), '{"a":1}');
  assert.equal(stripFence('```\n{"a":1}\n```'), '{"a":1}');
  assert.equal(stripFence('  {"a":1}  '), '{"a":1}');
});

test("product facts are read from a well-formed reply", () => {
  const facts = parseProductFacts(`{
    "suggestedName": "  Ceramic pour-over dripper  ",
    "suggestedCategory": "Home & Kitchen › Coffee",
    "material": "Glazed ceramic",
    "colour": "Matte white",
    "keyFeatures": ["Hand-glazed", "  ", "Fits 02 filters"],
    "visibleText": ["HARIO", "02"]
  }`);

  assert.equal(facts.suggestedName, "Ceramic pour-over dripper");
  assert.equal(facts.material, "Glazed ceramic");
  assert.deepEqual(facts.keyFeatures, ["Hand-glazed", "Fits 02 filters"]);
  // Packaging text is kept so a later composite can be checked against it
  // (SPEC §8).
  assert.deepEqual(facts.visibleText, ["HARIO", "02"]);
});

test("absent optional fields stay undefined rather than becoming the string null", () => {
  const facts = parseProductFacts('{"suggestedName":"Dripper","material":null,"colour":""}');
  assert.equal(facts.material, undefined);
  assert.equal(facts.colour, undefined);
  assert.deepEqual(facts.keyFeatures, []);
  assert.deepEqual(facts.visibleText, []);
});

test("a reply with no product name is refused instead of saving a blank listing", () => {
  assert.throws(() => parseProductFacts('{"suggestedCategory":"Coffee"}'), ProviderError);
  assert.throws(() => parseProductFacts('{"suggestedName":"   "}'), ProviderError);
});

test("unparseable output is a retryable provider error, not a crash", () => {
  const error = (() => {
    try { parseProductFacts("I think this is a coffee dripper!"); } catch (e) { return e as ProviderError; }
  })();
  assert.ok(error instanceof ProviderError);
  assert.equal(error.retryable, true);
  // SPEC §6: a failed generation must not be charged for.
  assert.equal(error.charged, false);
});

test("ad scripts are read and defaulted where the model was vague", () => {
  const scripts = parseAdScripts(`[
    {"hook":"Your pour-over is bitter for one reason","beats":["Show grind","Show bloom"],"durationSeconds":28},
    {"hook":"  Three seconds to a better cup  ","beats":[]}
  ]`);

  assert.equal(scripts.length, 2);
  assert.equal(scripts[0].durationSeconds, 28);
  assert.equal(scripts[1].hook, "Three seconds to a better cup");
  // Missing duration falls back rather than producing NaN downstream.
  assert.equal(scripts[1].durationSeconds, 30);
});

test("scripts without a hook are dropped — the first three seconds are the product", () => {
  const scripts = parseAdScripts('[{"hook":"","beats":["x"]},{"hook":"Real hook","beats":[]}]');
  assert.equal(scripts.length, 1);
  assert.equal(scripts[0].hook, "Real hook");
});

test("a reply with no usable script is an error, not an empty list", () => {
  // Returning [] would look like success and silently charge for nothing.
  assert.throws(() => parseAdScripts("[]"), ProviderError);
  assert.throws(() => parseAdScripts('[{"beats":["x"]}]'), ProviderError);
  assert.throws(() => parseAdScripts('{"hook":"not a list"}'), ProviderError);
});

test("provider errors never claim the seller was charged", () => {
  const error = new ProviderError("anthropic", "boom", true);
  assert.equal(error.charged, false);
  assert.equal(error.provider, "anthropic");
});
