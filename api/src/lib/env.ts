// Typed access to the provider credentials.
//
// Every getter is lazy. Reading a key at module load would make an unset
// variable break `next build` and every unrelated route, the same trap
// `supabaseAdmin()` avoids — so nothing throws until the call that needs it.

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} must be set.`);
  return value;
}

function optional(name: string, fallback: string): string {
  return process.env[name] || fallback;
}

/** Claude — product descriptions (vision) and ad scripts (text). */
export const anthropic = {
  apiKey: () => required("ANTHROPIC_API_KEY"),
  /** Reads the product photo to draft listing copy. */
  visionModel: () => optional("ANTHROPIC_VISION_MODEL", "claude-opus-5"),
  /**
   * Writes the short-form ad scripts (SPEC §2).
   *
   * Sonnet 5 rather than Opus: SPEC §6 prices an ad script at 2 credits
   * (~$0.04 of underlying cost), and Opus 5 output alone exceeds that. Sonnet
   * lands near $0.023 for the same call. Owner's decision, 2026-09-13.
   */
  scriptModel: () => optional("ANTHROPIC_SCRIPT_MODEL", "claude-sonnet-5"),
};

/**
 * Kling — background generation only.
 *
 * SPEC §8: the product is never redrawn. Kling produces a scene; the original
 * product pixels are composited onto it by us. Anything that sends the product
 * itself to a generative model belongs nowhere in this codebase.
 */
export const kling = {
  apiKey: () => required("KLING_API_KEY"),
  baseURL: () => optional("KLING_BASE_URL", "https://api.klingai.com").replace(/\/+$/, ""),
};

/**
 * Langfuse — SPEC §3 requires tracing on *all* model calls.
 *
 * The variable is `LANGFUSE_BASE_URL`, which is what the v5 SDK reads. An
 * earlier `LANGFUSE_HOST` here would have been ignored by the SDK, which would
 * then have silently shipped traces to the default cloud host instead of a
 * self-hosted one.
 */
export const langfuse = {
  publicKey: () => required("LANGFUSE_PUBLIC_KEY"),
  secretKey: () => required("LANGFUSE_SECRET_KEY"),
  baseURL: () => optional("LANGFUSE_BASE_URL", "https://cloud.langfuse.com"),
  /** Tracing is optional in dev; without keys the model call still runs. */
  isConfigured: () =>
    Boolean(process.env.LANGFUSE_PUBLIC_KEY && process.env.LANGFUSE_SECRET_KEY),
};

/** Variables with no default — absent means that feature cannot run. */
const REQUIRED_KEYS = [
  "ANTHROPIC_API_KEY",
  "KLING_API_KEY",
  "LANGFUSE_PUBLIC_KEY",
  "LANGFUSE_SECRET_KEY",
] as const;

/**
 * Which credentials are missing, without throwing.
 *
 * Lets a health check report the whole list at once instead of failing on the
 * first one — the same reason validate() returns every violation.
 */
export function missingCredentials(): string[] {
  return REQUIRED_KEYS.filter((name) => !process.env[name]);
}
