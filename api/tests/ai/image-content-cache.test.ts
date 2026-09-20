import { test } from "node:test";
import assert from "node:assert/strict";
import { createClient } from "@supabase/supabase-js";
import { studioContentHash, readStudioCache, writeStudioCache } from "../../src/lib/ai/image-content-cache.ts";
import { STUDIO_SCENES } from "../../src/lib/studio.ts";

const input = { cutout: Buffer.from("cutout"), scene: STUDIO_SCENES.BEAUTY[0], index: 0 };

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
