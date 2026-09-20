// Provider submissions incur real cost. Network recovery must query/download
// the existing task, never automatically start another paid generation.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { ImageError, KlingImageClient } from "../../src/lib/ai/image.ts";
import { STUDIO_SCENES } from "../../src/lib/studio.ts";

const previousKey = process.env.KLING_API_KEY;
before(() => { process.env.KLING_API_KEY = "stub-only-not-a-credential"; });
after(() => {
  if (previousKey === undefined) delete process.env.KLING_API_KEY;
  else process.env.KLING_API_KEY = previousKey;
});
const scene = STUDIO_SCENES.BEAUTY[0];
const subject = { data: Buffer.from("stub-photo"), mime: "image/png" };

function isImageError(context: Partial<ImageError>) {
  return (error: unknown) => {
    assert.ok(error instanceof ImageError);
    for (const [key, value] of Object.entries(context)) {
      assert.equal(error[key as keyof ImageError], value);
    }
    return true;
  };
}

test("timed-out submission is ambiguous and is never automatically resubmitted", async () => {
  let calls = 0;
  const client = new KlingImageClient({ requestTimeoutMs: 10, fetch: async (_url, init) => {
    calls++;
    return new Promise<Response>((_resolve, reject) => {
      init!.signal!.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true });
    });
  } });
  await assert.rejects(client.submit(subject, scene), isImageError({ phase: "submit", submissionUnknown: true, retryable: false }));
  assert.equal(calls, 1);
});

test("submission deadline includes reading the body, not just the response headers", async () => {
  let calls = 0;
  const client = new KlingImageClient({ requestTimeoutMs: 10, fetch: async (_url, init) => {
    calls++;
    return new Response(new ReadableStream({ start(controller) {
      controller.enqueue(new TextEncoder().encode('{"code":0,"data":'));
      init!.signal!.addEventListener("abort", () => controller.error(new DOMException("Aborted", "AbortError")), { once: true });
    } }));
  } });
  await assert.rejects(client.submit(subject, scene), isImageError({ phase: "submit", submissionUnknown: true }));
  assert.equal(calls, 1);
});

for (const [name, response] of [
  ["malformed JSON", () => new Response("not json")],
  ["missing task ID", () => Response.json({ code: 0, data: {} })],
  ["server failure", () => Response.json({ code: 500 }, { status: 503 })],
  ["request timeout", () => new Response("Timeout", { status: 408 })],
] as const) {
  test(`${name} must not authorize another paid submission`, async () => {
    let calls = 0;
    const client = new KlingImageClient({ fetch: async () => { calls++; return response(); } });
    await assert.rejects(client.submit(subject, scene), isImageError({ submissionUnknown: true, retryable: false }));
    assert.equal(calls, 1);
  });
}

test("definite provider balance rejection is distinguishable from an uncertain submission", async () => {
  const client = new KlingImageClient({ fetch: async () => Response.json({ code: 1102 }) });
  await assert.rejects(client.submit(subject, scene), isImageError({ submissionUnknown: false, retryable: false }));
});

test("status failure and download failure recover the same paid task with a single POST", async () => {
  const methods: string[] = [];
  const paths: string[] = [];
  let polls = 0;
  let downloads = 0;
  const client = new KlingImageClient({ fetch: async (url, init) => {
    methods.push(init?.method ?? "GET");
    const path = new URL(String(url)).pathname;
    paths.push(path);
    if (init?.method === "POST") return Response.json({ code: 0, data: { task_id: "paid-task" } });
    if (path.endsWith("/paid-task")) {
      polls++;
      if (polls === 1) throw new TypeError("Connection lost");
      if (polls === 2) return Response.json({ code: 0, data: { task_status: "processing" } });
      return Response.json({ code: 0, data: { task_status: "succeed", task_result: { images: [{ url: "https://example.test/result.png" }] } } });
    }
    downloads++;
    if (downloads === 1) throw new TypeError("Connection lost");
    return new Response("stub-image", { headers: { "Content-Type": "image/png" } });
  } });
  const task = await client.submit(subject, scene);
  await assert.rejects(client.status(task.taskId), isImageError({ phase: "status", taskId: "paid-task", retryable: true }));
  assert.deepEqual(await client.status(task.taskId), { status: "processing" });
  const result = await client.status(task.taskId);
  assert.equal(result.status, "completed");
  if (result.status !== "completed") throw new Error("Expected image");
  await assert.rejects(client.download(result.url), isImageError({ phase: "download", retryable: true }));
  assert.equal((await client.download(result.url)).data.toString(), "stub-image");
  assert.equal(methods.filter(method => method === "POST").length, 1);
  assert.equal(paths.filter(path => path.endsWith("/paid-task")).length, 3);
});

test("stalled downloads abort without submitting another paid task", async () => {
  let calls = 0;
  const client = new KlingImageClient({ downloadTimeoutMs: 10, fetch: async (_url, init) => {
    calls++;
    assert.notEqual(init?.method, "POST");
    return new Response(new ReadableStream({ start(controller) {
      init!.signal!.addEventListener("abort", () => controller.error(new DOMException("Aborted", "AbortError")), { once: true });
    } }), { headers: { "Content-Type": "image/png" } });
  } });
  await assert.rejects(client.download("https://example.test/result.png"), isImageError({ phase: "download", retryable: true }));
  assert.equal(calls, 1);
});

test("provider failure is not output eligible for charging", async () => {
  const client = new KlingImageClient({ fetch: async () => Response.json({ code: 0, data: { task_status: "failed" } }) });
  assert.deepEqual(await client.status("paid-task"), { status: "failed" });
});

test("unknown status and success without an image are not treated as completed", async () => {
  for (const data of [{ task_status: "unknown" }, { task_status: "succeed" }]) {
    const client = new KlingImageClient({ fetch: async () => Response.json({ code: 0, data }) });
    await assert.rejects(client.status("paid-task"), isImageError({ phase: "status", taskId: "paid-task" }));
  }
});

test("empty, non-image and oversized downloads are not output eligible for charging", async () => {
  for (const response of [
    () => new Response("", { headers: { "Content-Type": "image/png" } }),
    () => new Response("upstream error", { headers: { "Content-Type": "text/html" } }),
    () => new Response(new Uint8Array(20 * 1024 * 1024 + 1), { headers: { "Content-Type": "image/png" } }),
  ]) {
    const client = new KlingImageClient({ fetch: async () => response() });
    await assert.rejects(client.download("https://example.test/result.png"), isImageError({ phase: "download" }));
  }
});
