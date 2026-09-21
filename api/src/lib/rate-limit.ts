// Shared fixed-window rate limiter backed by the `rate_limits` table
// (migration 0007). Used to throttle abuse-prone endpoints: OTP sending,
// sign-in attempts, and content reports.
//
// FAIL-OPEN: if the limiter backend is unavailable, requests are allowed. A
// limiter must never take the whole service down — and this also means the
// feature is safe to deploy before its migration has run.

import { supabaseAdmin } from "./supabase.ts";

export interface RateLimit {
  limit: number;
  windowSeconds: number;
}

export interface RateLimitResult {
  allowed: boolean;
  retryAfterSeconds: number;
}

/** Sensible defaults for each throttled action. */
export const RATE_LIMITS = {
  otpPerEmail: { limit: 3, windowSeconds: 600 },   // 3 codes / 10 min to one address
  otpPerIp: { limit: 15, windowSeconds: 600 },     // 15 code requests / 10 min per IP
  verifyPerIp: { limit: 30, windowSeconds: 600 },  // 30 verify attempts / 10 min per IP
  applePerIp: { limit: 30, windowSeconds: 600 },
  reportPerOrg: { limit: 20, windowSeconds: 3600 },
} as const satisfies Record<string, RateLimit>;

/** Counts one hit against `bucket`; returns whether it is still within `limit`. */
export async function rateLimit(bucket: string, { limit, windowSeconds }: RateLimit): Promise<RateLimitResult> {
  try {
    const { data, error } = await supabaseAdmin().rpc("rate_limit_hit", {
      p_bucket: bucket,
      p_window_seconds: windowSeconds,
    });
    if (error || typeof data !== "number") return { allowed: true, retryAfterSeconds: 0 };
    return data <= limit
      ? { allowed: true, retryAfterSeconds: 0 }
      : { allowed: false, retryAfterSeconds: windowSeconds };
  } catch {
    return { allowed: true, retryAfterSeconds: 0 };
  }
}

/** The best available client IP on Vercel; a stable fallback keeps a bucket. */
export function clientIp(request: Request): string {
  const forwarded = request.headers.get("x-forwarded-for");
  if (forwarded) return forwarded.split(",")[0].trim();
  return request.headers.get("x-real-ip")?.trim() || "unknown";
}
