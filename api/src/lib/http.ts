import { NextResponse } from "next/server";
import { headers } from "next/headers";
import { languageFromHeader, localize } from "./i18n/index.ts";
import type { OutputLanguage } from "./ai/types.ts";

export function json<T>(data: T, status = 200): NextResponse {
  return NextResponse.json(data, { status });
}

/**
 * The language this request asked for.
 *
 * Read from the request context rather than threaded through every handler, so
 * a seller-facing message is translated wherever it is produced — including the
 * ones thrown deep in a library and caught as `e.message`. Outside a request
 * (a unit test, a script) there is no context and English is correct.
 */
async function requestLanguage(): Promise<OutputLanguage> {
  try {
    return languageFromHeader((await headers()).get("accept-language"));
  } catch {
    return "en";
  }
}

// Every error path returns { error } — the iOS APIClient decodes exactly this
// shape from non-2xx responses (see APIClient.swift). `extra` carries the
// machine-readable fields some errors add, such as the credits a purchase needs.
export async function error(
  message: string,
  status = 400,
  extra?: Record<string, unknown>,
): Promise<NextResponse> {
  return NextResponse.json(
    { ...extra, error: localize(message, await requestLanguage()) },
    { status },
  );
}

// 429 with Retry-After. Same { error } body the iOS client already decodes.
export async function tooMany(message: string, retryAfterSeconds: number): Promise<NextResponse> {
  return NextResponse.json({ error: localize(message, await requestLanguage()) }, {
    status: 429,
    headers: { "Retry-After": String(Math.max(1, Math.ceil(retryAfterSeconds))) },
  });
}
