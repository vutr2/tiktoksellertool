// Turns token counts into the `actual_cost_usd` that every `generations` row
// must carry (SPEC §9: "I need real margin numbers, not estimates").
//
// The rule this file exists to enforce: an unknown price returns null, never a
// guess. A fabricated cost is worse than a missing one — it silently corrupts
// the margin numbers the whole credit model is priced against.

export interface TokenRate {
  /** USD per million input tokens. */
  inputPerMTok: number;
  /** USD per million output tokens. */
  outputPerMTok: number;
}

/**
 * Anthropic list prices, taken from the claude-api skill's table
 * (cached 2026-06-24). These change — re-check before trusting a margin report.
 *
 * TODO_VERIFY: confirm against the live pricing page each time the model
 * changes, the same discipline the marketplace rules follow.
 */
const ANTHROPIC_RATES: Record<string, TokenRate> = {
  "claude-opus-5": { inputPerMTok: 5, outputPerMTok: 25 },
  "claude-sonnet-5": { inputPerMTok: 2, outputPerMTok: 10 },
  "claude-haiku-4-5": { inputPerMTok: 1, outputPerMTok: 5 },
};

/** Cached input is billed at roughly a tenth of the normal input rate. */
const CACHE_READ_MULTIPLIER = 0.1;

export interface TokenCounts {
  inputTokens: number;
  outputTokens: number;
  /** Subset of the input that was served from cache, not additional to it. */
  cachedInputTokens?: number;
}

/**
 * Cost of one Anthropic call, or null when the model's rate is not known here.
 *
 * Callers must treat null as "cost unrecorded" and surface it, rather than
 * defaulting to zero — a zero would read as a free call in the margin numbers.
 */
export function anthropicCostUSD(model: string, counts: TokenCounts): number | null {
  const rate = ANTHROPIC_RATES[model];
  if (!rate) return null;

  const cached = counts.cachedInputTokens ?? 0;
  const uncachedInput = Math.max(0, counts.inputTokens - cached);

  const input = (uncachedInput / 1_000_000) * rate.inputPerMTok;
  const cachedInput = (cached / 1_000_000) * rate.inputPerMTok * CACHE_READ_MULTIPLIER;
  const output = (counts.outputTokens / 1_000_000) * rate.outputPerMTok;

  return input + cachedInput + output;
}

/**
 * Cost of one Kling background render.
 *
 * Kling bills per generation rather than per token, and the rate depends on the
 * plan — so it comes from `KLING_COST_USD_PER_IMAGE`, set from the actual
 * invoice. Unset means unknown, and unknown means null.
 */
export function klingCostUSD(): number | null {
  const raw = process.env.KLING_COST_USD_PER_IMAGE;
  if (!raw) return null;
  const value = Number(raw);
  return Number.isFinite(value) && value >= 0 ? value : null;
}

/** Models this file can price. Useful for a startup sanity check. */
export function pricedModels(): string[] {
  return Object.keys(ANTHROPIC_RATES);
}
