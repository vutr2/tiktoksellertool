import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { anthropicCostUSD, klingCostUSD, pricedModels } from "../../src/lib/ai/pricing.ts";

beforeEach(() => {
  delete process.env.KLING_COST_USD_PER_IMAGE;
});

const near = (actual: number | null, expected: number, label: string) => {
  assert.ok(actual !== null, `${label}: got null`);
  assert.ok(Math.abs(actual - expected) < 1e-9, `${label}: ${actual} != ${expected}`);
};

test("a known model prices input and output at its published rates", () => {
  // Opus 5: $5 per MTok in, $25 per MTok out.
  near(anthropicCostUSD("claude-opus-5", { inputTokens: 1_000_000, outputTokens: 0 }), 5, "input");
  near(anthropicCostUSD("claude-opus-5", { inputTokens: 0, outputTokens: 1_000_000 }), 25, "output");
  near(
    anthropicCostUSD("claude-opus-5", { inputTokens: 200_000, outputTokens: 100_000 }),
    1 + 2.5,
    "combined",
  );
});

test("an unknown model returns null, never zero", () => {
  // Zero would read as a free call and silently corrupt the margin numbers
  // SPEC §9 exists to protect.
  assert.equal(anthropicCostUSD("claude-some-future-model", { inputTokens: 1000, outputTokens: 1000 }), null);
  assert.notEqual(anthropicCostUSD("gpt-4", { inputTokens: 1000, outputTokens: 1000 }), 0);
});

test("cached input is discounted and not billed twice", () => {
  // cachedInputTokens is a SUBSET of inputTokens, not extra on top.
  const allCached = anthropicCostUSD("claude-opus-5", {
    inputTokens: 1_000_000,
    outputTokens: 0,
    cachedInputTokens: 1_000_000,
  });
  near(allCached, 0.5, "fully cached costs a tenth");

  const halfCached = anthropicCostUSD("claude-opus-5", {
    inputTokens: 1_000_000,
    outputTokens: 0,
    cachedInputTokens: 500_000,
  });
  near(halfCached, 2.5 + 0.25, "half cached");

  assert.ok(halfCached! < 5, "caching must never cost more than not caching");
});

test("a cached count larger than the input never produces a negative cost", () => {
  const cost = anthropicCostUSD("claude-opus-5", {
    inputTokens: 1000,
    outputTokens: 0,
    cachedInputTokens: 9_999_999,
  });
  assert.ok(cost !== null && cost >= 0, `got ${cost}`);
});

test("a zero-token call costs nothing", () => {
  near(anthropicCostUSD("claude-opus-5", { inputTokens: 0, outputTokens: 0 }), 0, "zero");
});

test("Kling cost comes from the invoice, and is null when unset", () => {
  assert.equal(klingCostUSD(), null, "unset means unknown, not free");

  process.env.KLING_COST_USD_PER_IMAGE = "0.035";
  assert.equal(klingCostUSD(), 0.035);

  process.env.KLING_COST_USD_PER_IMAGE = "not-a-number";
  assert.equal(klingCostUSD(), null, "garbage must not become a cost");

  process.env.KLING_COST_USD_PER_IMAGE = "-1";
  assert.equal(klingCostUSD(), null, "negative must not become a cost");
});

test("the credit price in SPEC §6 does not cover an ad script on Opus 5", () => {
  // SPEC §6: an ad script costs 2 credits, and "1 credit ≈ $0.02 underlying
  // cost" — a $0.04 budget. This pins the tradeoff rather than asserting a
  // choice: picking the model is the owner's call, but the numbers are not.
  const BUDGET_USD = 2 * 0.02;
  const call = { inputTokens: 1500, outputTokens: 2000 };

  const opus = anthropicCostUSD("claude-opus-5", call)!;
  const sonnet = anthropicCostUSD("claude-sonnet-5", call)!;
  const haiku = anthropicCostUSD("claude-haiku-4-5", call)!;

  assert.ok(opus > BUDGET_USD, `Opus 5 at $${opus.toFixed(4)} should exceed $${BUDGET_USD}`);
  assert.ok(sonnet < BUDGET_USD, `Sonnet 5 at $${sonnet.toFixed(4)} should fit`);
  assert.ok(haiku < sonnet, "Haiku should be the cheapest of the three");
});

test("every priced model is quotable", () => {
  for (const model of pricedModels()) {
    assert.notEqual(anthropicCostUSD(model, { inputTokens: 1000, outputTokens: 1000 }), null, model);
  }
  assert.ok(pricedModels().includes("claude-opus-5"));
});
