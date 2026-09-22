// Product fidelity and charging eligibility (SPEC §8 / §6). Provider calls are
// stubbed: these tests never upload product photos or pay for image generation.
import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import sharp from "sharp";
import { composeScene, forgetImageTask, ImageError } from "../../src/lib/ai/image.ts";
import { STUDIO_SCENES } from "../../src/lib/studio.ts";

function provider(t: TestContext, name: "xai" | "kling") {
  const keys = ["XAI_API_KEY", "XAI_IMAGE_MODEL", "XAI_BASE_URL", "KLING_API_KEY", "KLING_BASE_URL"];
  const previous = keys.map(key => process.env[key]);
  t.after(() => keys.forEach((key, index) => {
    if (previous[index] === undefined) delete process.env[key];
    else process.env[key] = previous[index];
  }));
  delete process.env.XAI_IMAGE_MODEL;
  if (name === "xai") {
    process.env.XAI_API_KEY = "stub-key";
    process.env.XAI_BASE_URL = "https://image-api.invalid/v1";
  } else {
    delete process.env.XAI_API_KEY;
    process.env.KLING_API_KEY = "stub-key";
    process.env.KLING_BASE_URL = "https://image-api.invalid";
  }
}

async function cutout() {
  // Transparent border with an opaque product-colour swatch in the centre.
  const data = await sharp({ create: { width: 200, height: 300, channels: 4,
    background: { r: 0, g: 0, b: 0, alpha: 0 } } })
    .composite([{ input: await sharp({ create: { width: 120, height: 200, channels: 4,
      background: { r: 19, g: 113, b: 207, alpha: 1 } } }).png().toBuffer(), left: 40, top: 50 }])
    .png().toBuffer();
  return { data, mime: "image/png" };
}

test("Grok receives the original alpha PNG and an explicit frame, without pre-cropping the product", async t => {
  provider(t, "xai");
  const subject = await cutout();
  const requests: Record<string, unknown>[] = [];
  t.mock.method(globalThis, "fetch", async (url: string, init: RequestInit) => {
    assert.equal(String(url), "https://image-api.invalid/v1/images/edits");
    requests.push(JSON.parse(String(init.body)));
    return Response.json({ data: [{ b64_json: subject.data.toString("base64") }] });
  });
  for (const scene of STUDIO_SCENES.BEAUTY.slice(0, 4)) {
    await composeScene(subject, scene, `grok-fidelity-${scene.id}`);
  }
  assert.deepEqual(requests.map(request => request.aspect_ratio), ["1:1", "3:4", "1:1", "9:16"]);
  for (const request of requests) {
    assert.deepEqual(request.image, { type: "image_url", url: `data:image/png;base64,${subject.data.toString("base64")}` });
    assert.equal(request.model, "grok-imagine-image-2.0");
    const image = request.image as { url: string };
    assert.equal((await sharp(Buffer.from(image.url.split(",")[1], "base64")).metadata()).hasAlpha, true);
  }
});

function klingOutput(t: TestContext, background: Buffer) {
  t.mock.method(globalThis, "fetch", async (url: string, init: RequestInit = {}) => {
    if (init.method === "POST") {
      const request = JSON.parse(String(init.body));
      // The model cannot redraw the customer's product if it never receives it.
      assert.equal(request.image, undefined);
      assert.equal(request.image_reference, undefined);
      return Response.json({ code: 0, data: { task_id: "stub-task" } });
    }
    if (String(url).endsWith("/stub-task")) {
      return Response.json({ code: 0, data: { task_status: "succeed",
        task_result: { images: [{ url: "https://image-output.invalid/background.png" }] } } });
    }
    assert.equal(String(url), "https://image-output.invalid/background.png");
    return new Response(new Uint8Array(background), { headers: { "Content-Type": "image/png" } });
  });
}

test("Kling output contains the original product colour and alpha border, exported losslessly", async t => {
  provider(t, "kling");
  const background = await sharp({ create: { width: 400, height: 400, channels: 3, background: "white" } }).png().toBuffer();
  klingOutput(t, background);
  const key = "kling-product-fidelity";
  t.after(() => forgetImageTask(key));
  const result = await composeScene(await cutout(), STUDIO_SCENES.BEAUTY[0], key);
  assert.equal(result.mime, "image/png");
  assert.equal((await sharp(result.data).metadata()).format, "png");
  const pixel = async (left: number, top: number) => Array.from(await sharp(result.data)
    .removeAlpha().extract({ left, top, width: 1, height: 1 }).raw().toBuffer());
  assert.deepEqual(await pixel(200, 200), [19, 113, 207], "No diffusion redraw or lossy JPEG colour change");
  assert.deepEqual(await pixel(0, 0), [255, 255, 255], "The transparent source border must not become a black rectangle");
});

test("a failed composite cannot return an empty background eligible for charging", async t => {
  provider(t, "kling");
  const background = await sharp({ create: { width: 32, height: 32, channels: 3, background: "white" } }).png().toBuffer();
  klingOutput(t, background);
  const key = "kling-invalid-product";
  t.after(() => forgetImageTask(key));
  await assert.rejects(composeScene({ data: Buffer.from("invalid cutout"), mime: "image/png" }, STUDIO_SCENES.BEAUTY[0], key),
    (error: unknown) => error instanceof ImageError && error.phase === "composite");
});
