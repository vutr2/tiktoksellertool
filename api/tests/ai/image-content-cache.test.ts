import { before, after, test } from "node:test";
import assert from "node:assert/strict";
import { createClient } from "@supabase/supabase-js";
import { studioContentHash, readStudioCache, writeStudioCache } from "../../src/lib/ai/image-content-cache.ts";
import { STUDIO_SCENES } from "../../src/lib/studio.ts";
import { studioRenderFingerprint } from "../../src/lib/ai/image.ts";

const originalXAIKey = process.env.XAI_API_KEY;
before(() => { delete process.env.XAI_API_KEY; });
after(() => {
  if (originalXAIKey === undefined) delete process.env.XAI_API_KEY;
  else process.env.XAI_API_KEY = originalXAIKey;
});

const input = { cutout: Buffer.from("cutout"), scene: STUDIO_SCENES.BEAUTY[0], index: 0 };

test("Grok cache follows the actual provider, model, edit instructions and aspect ratio", () => {
  const klingHash = studioContentHash(input);
  const previousModel = process.env.XAI_IMAGE_MODEL;
  try {
    process.env.XAI_API_KEY = "stub-only";
    delete process.env.XAI_IMAGE_MODEL;
    const grokHash = studioContentHash(input);
    const fingerprint = studioRenderFingerprint(input.scene) as { provider: string; model: string; prompt: string };
    assert.equal(fingerprint.provider, "xai");
    assert.equal(fingerprint.model, "grok-imagine-image-2.0");
    assert.ok(fingerprint.prompt.includes("transparent alpha background"));
    assert.notEqual(grokHash, klingHash);
    assert.notEqual(studioContentHash({ ...input, scene: { ...input.scene, aspect: "9:16" } }), grokHash);
    process.env.XAI_IMAGE_MODEL = "different-stub-model";
    assert.notEqual(studioContentHash(input), grokHash);
  } finally {
    delete process.env.XAI_API_KEY;
    if (previousModel === undefined) delete process.env.XAI_IMAGE_MODEL;
    else process.env.XAI_IMAGE_MODEL = previousModel;
  }
});

test("identical render inputs hit one content key; new variants require a new render", () => {
  const hash = studioContentHash(input);
  assert.equal(studioContentHash({ ...input, cutout: Buffer.from("cutout") }), hash);
  for (const changed of [
    { ...input, cutout: Buffer.from("another product") },
    { ...input, index: 1 },
    { ...input, scene: { ...input.scene, prompt: "changed scene" } },
    { ...input, scene: { ...input.scene, negative: "changed constraints" } },
  ]) assert.notEqual(studioContentHash(changed), hash);
  const previous = process.env.KLING_IMAGE_MODEL;
  try {
    process.env.KLING_IMAGE_MODEL = "different-test-model";
    assert.notEqual(studioContentHash(input), hash);
  } finally {
    if (previous === undefined) delete process.env.KLING_IMAGE_MODEL;
    else process.env.KLING_IMAGE_MODEL = previous;
  }
});

test("cache data is scoped to the organization even when input hashes match", async () => {
  const paths: string[] = [];
  const db = createClient("https://cache.invalid", "stub-key", { global: { fetch: async (url) => {
    paths.push(new URL(String(url)).pathname);
    return new Response("cached-image", { headers: { "Content-Type": "image/png" } });
  } }, auth: { persistSession: false } });
  const hash = studioContentHash(input);
  assert.equal((await readStudioCache("owner-a", hash, db))?.data.toString(), "cached-image");
  await readStudioCache("owner-b", hash, db);
  assert.equal(paths.length, 2);
  assert.ok(paths[0].endsWith(`/owner-a/_studio-cache/${hash}.png`));
  assert.ok(paths[1].endsWith(`/owner-b/_studio-cache/${hash}.png`));
});

test("a confirmed storage miss permits rendering; a storage outage must not trigger paid regeneration", async () => {
  for (const status of [404, 503, 403]) {
    const db = createClient("https://cache.invalid", "stub-key", { global: { fetch: async () =>
      Response.json({ statusCode: String(status), error: "stub", message: "stub" }, { status: 400 }),
    }, auth: { persistSession: false } });
    if (status === 404) assert.equal(await readStudioCache("owner", "hash", db), null);
    else await assert.rejects(readStudioCache("owner", "hash", db), /Could not check the image cache/);
  }
});

test("optional cache write failure does not report failure after a paid image was saved", async (t) => {
  t.mock.method(console, "warn", () => {});
  const db = createClient("https://cache.invalid", "stub-key", { global: { fetch: async () =>
    Response.json({ statusCode: "403", error: "stub", message: "stub" }, { status: 400 }),
  }, auth: { persistSession: false } });
  await writeStudioCache("owner", "hash", { data: Buffer.from("result"), mime: "image/png" }, db);
});
