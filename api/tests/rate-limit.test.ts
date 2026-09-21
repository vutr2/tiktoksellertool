import { test } from "node:test";
import assert from "node:assert/strict";
import { clientIp, RATE_LIMITS } from "../src/lib/rate-limit.ts";

function req(headers: Record<string, string>): Request {
  return new Request("https://example.com", { headers });
}

test("clientIp takes the first x-forwarded-for hop", () => {
  assert.equal(clientIp(req({ "x-forwarded-for": "203.0.113.7, 10.0.0.1" })), "203.0.113.7");
});

test("clientIp trims whitespace", () => {
  assert.equal(clientIp(req({ "x-forwarded-for": "  198.51.100.2  " })), "198.51.100.2");
});

test("clientIp falls back to x-real-ip", () => {
  assert.equal(clientIp(req({ "x-real-ip": "192.0.2.9" })), "192.0.2.9");
});

test("clientIp returns a stable bucket when no IP header is present", () => {
  assert.equal(clientIp(req({})), "unknown");
});

test("every rate limit has a positive limit and window", () => {
  for (const [name, cfg] of Object.entries(RATE_LIMITS)) {
    assert.ok(cfg.limit > 0, `${name} limit`);
    assert.ok(cfg.windowSeconds > 0, `${name} window`);
  }
});
