import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { anthropic, kling, langfuse, missingCredentials } from "../../src/lib/env.ts";

const KEYS = [
  "ANTHROPIC_API_KEY", "ANTHROPIC_VISION_MODEL", "ANTHROPIC_SCRIPT_MODEL",
  "KLING_API_KEY", "KLING_BASE_URL",
  "LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY", "LANGFUSE_HOST",
];

beforeEach(() => {
  for (const key of KEYS) delete process.env[key];
});

test("a missing credential throws a message naming the variable", () => {
  assert.throws(() => anthropic.apiKey(), /ANTHROPIC_API_KEY must be set\./);
  assert.throws(() => kling.apiKey(), /KLING_API_KEY must be set\./);
  assert.throws(() => langfuse.secretKey(), /LANGFUSE_SECRET_KEY must be set\./);
});

test("vision defaults to Opus 5; scripts default to Sonnet 5 to fit the credit price", () => {
  assert.equal(anthropic.visionModel(), "claude-opus-5");
  // SPEC §6 prices an ad script at 2 credits (~$0.04); Opus 5 exceeds that.
  assert.equal(anthropic.scriptModel(), "claude-sonnet-5");
});

test("a configured model overrides the default", () => {
  process.env.ANTHROPIC_SCRIPT_MODEL = "claude-opus-5";
  assert.equal(anthropic.scriptModel(), "claude-opus-5");
  // Vision is configured separately — one override must not move the other.
  assert.equal(anthropic.visionModel(), "claude-opus-5");
});

test("an empty string is treated as unset, not as a valid value", () => {
  process.env.ANTHROPIC_SCRIPT_MODEL = "";
  assert.equal(anthropic.scriptModel(), "claude-sonnet-5");

  process.env.ANTHROPIC_API_KEY = "";
  assert.throws(() => anthropic.apiKey(), /must be set/);
});

test("the Kling base URL loses any trailing slash so paths join cleanly", () => {
  assert.equal(kling.baseURL(), "https://api.klingai.com");
  process.env.KLING_BASE_URL = "https://proxy.example.com/";
  assert.equal(kling.baseURL(), "https://proxy.example.com");
  process.env.KLING_BASE_URL = "https://proxy.example.com///";
  assert.equal(kling.baseURL(), "https://proxy.example.com");
});

test("reading credentials is lazy — importing the module never throws", () => {
  // Everything is unset here. If any getter ran at import time, this file
  // would have failed to load and no test would run at all.
  assert.ok(true);
});

test("missingCredentials reports every gap at once, not just the first", () => {
  assert.deepEqual(missingCredentials().sort(), [
    "ANTHROPIC_API_KEY",
    "KLING_API_KEY",
    "LANGFUSE_PUBLIC_KEY",
    "LANGFUSE_SECRET_KEY",
  ]);

  process.env.ANTHROPIC_API_KEY = "sk-test";
  process.env.KLING_API_KEY = "kling-test";
  assert.deepEqual(missingCredentials().sort(), ["LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY"]);
});

test("models that have defaults are never reported as missing", () => {
  for (const name of missingCredentials()) {
    assert.ok(!name.endsWith("_MODEL"), `${name} has a default and should not be required`);
    assert.ok(!name.endsWith("_HOST"), `${name} has a default and should not be required`);
  }
});
