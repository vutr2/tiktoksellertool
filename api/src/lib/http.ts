import { NextResponse } from "next/server";

export function json<T>(data: T, status = 200): NextResponse {
  return NextResponse.json(data, { status });
}

// Every error path returns { error } — the iOS APIClient decodes exactly this
// shape from non-2xx responses (see APIClient.swift).
export function error(message: string, status = 400): NextResponse {
  return NextResponse.json({ error: message }, { status });
}

// 429 with Retry-After. Same { error } body the iOS client already decodes.
export function tooMany(message: string, retryAfterSeconds: number): NextResponse {
  return NextResponse.json({ error: message }, {
    status: 429,
    headers: { "Retry-After": String(Math.max(1, Math.ceil(retryAfterSeconds))) },
  });
}
