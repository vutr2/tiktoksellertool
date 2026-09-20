// Kling redraws its reference image; prompt instructions do not guarantee
// original product pixels. See SPEC §8 before claiming label preservation.

import { kling } from "../env.ts";
import { PRESERVE_PRODUCT, type StudioScene } from "../studio.ts";
import { createHash } from "node:crypto";
import { ImageTaskCache } from "./image-task-cache.ts";

type ImagePhase = "submit" | "status" | "download" | "wait";

export class ImageError extends Error {
  readonly retryable: boolean;
  readonly phase?: ImagePhase;
  /** A timed-out POST may already have created a billable provider task. */
  readonly submissionUnknown: boolean;
  readonly taskId?: string;

  constructor(message: string, retryable = true, context: {
    phase?: ImagePhase; submissionUnknown?: boolean; taskId?: string;
  } = {}) {
    super(message);
    this.name = "ImageError";
    this.retryable = retryable;
    this.phase = context.phase;
    this.submissionUnknown = context.submissionUnknown ?? false;
    this.taskId = context.taskId;
  }
}

export type ImageBlob = { data: Buffer; mime: string };
export type ImageTaskStatus =
  | { status: "processing" }
  | { status: "completed"; url: string }
  | { status: "failed" };

const KLING_ASPECT: Record<string, string> = {
  "1:1": "1:1", "4:5": "3:4", "3:4": "3:4", "9:16": "9:16", "16:9": "16:9",
};
const MAX_IMAGE_BYTES = 20 * 1024 * 1024;

type KlingTask = {
  code?: number;
  data?: {
    task_id?: string;
    task_status?: string;
    task_result?: { images?: { url?: string }[] };
  };
};

/** Each operation is one bounded HTTP request, with no automatic paid retries. */
export class KlingImageClient {
  private readonly fetcher: typeof fetch;
  private readonly requestTimeoutMs: number;
  private readonly downloadTimeoutMs: number;

  constructor(options: {
    fetch?: typeof fetch; requestTimeoutMs?: number; downloadTimeoutMs?: number;
  } = {}) {
    this.fetcher = options.fetch ?? fetch;
    this.requestTimeoutMs = options.requestTimeoutMs ?? 20_000;
    this.downloadTimeoutMs = options.downloadTimeoutMs ?? 20_000;
  }

  async submit(subject: ImageBlob, scene: StudioScene): Promise<{ taskId: string; model: string }> {
    const model = process.env.KLING_IMAGE_MODEL ?? "kling-v2-1";
    const json = await this.call("POST", "/v1/images/generations", {
      model_name: model,
      prompt: `${scene.prompt}\n\n${PRESERVE_PRODUCT}`,
      negative_prompt: scene.negative,
      image: subject.data.toString("base64"),
      image_reference: "subject",
      image_fidelity: 0.9,
      aspect_ratio: KLING_ASPECT[scene.aspect] ?? "1:1",
      n: 1,
    });
    const taskId = json.data?.task_id;
    if (typeof taskId !== "string" || !taskId.trim()) {
      throw new ImageError("The image service did not return a task ID. Submission needs checking before retrying.", false,
        { phase: "submit", submissionUnknown: true });
    }
    return { taskId, model };
  }

  async status(taskId: string): Promise<ImageTaskStatus> {
    const json = await this.call("GET", `/v1/images/generations/${encodeURIComponent(taskId)}`, undefined, taskId);
    switch (json.data?.task_status) {
      case "submitted":
      case "processing": return { status: "processing" };
      case "failed": return { status: "failed" };
      case "succeed": {
        const url = json.data?.task_result?.images?.[0]?.url;
        if (typeof url === "string" && url.startsWith("https://")) return { status: "completed", url };
        throw new ImageError("The image service has not returned a valid image URL. Check this task again.", true,
          { phase: "status", taskId });
      }
      default:
        throw new ImageError("Could not read the image task status. Check this task again.", true,
          { phase: "status", taskId });
    }
  }

  async download(url: string): Promise<ImageBlob> {
    if (!url.startsWith("https://")) throw new ImageError("Invalid generated image URL.", false, { phase: "download" });
    return this.withDeadline("download", this.downloadTimeoutMs, async (signal) => {
      const res = await this.fetcher(url, { signal });
      if (!res.ok || !res.body) throw new ImageError(`Could not download the generated image (${res.status}).`, true,
        { phase: "download" });
      const mime = res.headers.get("content-type")?.split(";")[0].trim().toLowerCase();
      if (!mime || !["image/png", "image/jpeg", "image/webp"].includes(mime)) {
        await res.body.cancel();
        throw new ImageError("The image service returned an unsupported image format.", false, { phase: "download" });
      }
      // Bound the body as well as waiting for headers. Stalled or oversized
      // downloads must not occupy a Vercel invocation indefinitely.
      const reader = res.body.getReader();
      const chunks: Uint8Array[] = [];
      let size = 0;
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > MAX_IMAGE_BYTES) {
            await reader.cancel();
            throw new ImageError("The generated image is too large to save.", false, { phase: "download" });
          }
          chunks.push(value);
        }
      } finally {
        reader.releaseLock();
      }
      if (!size) throw new ImageError("The image service returned an empty image.", true, { phase: "download" });
      return { data: Buffer.concat(chunks), mime };
    });
  }

  private async call(method: "GET" | "POST", path: string, body?: unknown, taskId?: string): Promise<KlingTask> {
    const phase = method === "POST" ? "submit" : "status";
    // Missing credentials are a configuration error, not an ambiguous POST.
    const authorization = `Bearer ${kling.apiKey()}`;
    const url = `${kling.baseURL()}${path}`;
    return this.withDeadline(phase, this.requestTimeoutMs, async (signal) => {
      const res = await this.fetcher(url, {
        method,
        headers: { Authorization: authorization, "Content-Type": "application/json" },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal,
      });
      // Body consumption stays inside the deadline, including malformed JSON.
      const raw: unknown = await res.json().catch((err: unknown) => {
        if (signal.aborted) throw err;
        return null;
      });
      const json = raw && typeof raw === "object" && !Array.isArray(raw) ? raw as KlingTask : null;
      if (!res.ok || (json?.code !== undefined && json.code !== 0)) {
        const unknown = method === "POST" && (res.status >= 500 || res.status === 408);
        const retryable = !unknown && json?.code !== 1102 && res.status !== 401 && res.status !== 403;
        throw new ImageError(`Image service error (${res.status}/${json?.code ?? "unknown"}).` +
          (unknown ? " Submission needs checking before retrying." : ""), retryable,
        { phase, submissionUnknown: unknown, taskId });
      }
      if (!json) throw new ImageError("The image service returned an invalid response." +
        (method === "POST" ? " Submission needs checking before retrying." : " Check this task again."), method !== "POST",
        { phase, submissionUnknown: method === "POST", taskId });
      return json;
    }, taskId);
  }

  private async withDeadline<T>(phase: ImagePhase, timeoutMs: number,
    run: (signal: AbortSignal) => Promise<T>, taskId?: string): Promise<T> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      return await run(controller.signal);
    } catch (err) {
      if (err instanceof ImageError) throw err;
      const detail = controller.signal.aborted ? "took too long" : "could not connect";
      throw new ImageError(`Image service ${phase} ${detail}.` +
        (phase === "submit" ? " Submission needs checking before retrying." : " Check the existing task again."),
      phase !== "submit", { phase, submissionUnknown: phase === "submit", taskId });
    } finally {
      clearTimeout(timer);
    }
  }
}

const tasks = new ImageTaskCache();

/** Drop task metadata only after the durable asset has been saved and charged. */
export function forgetImageTask(cacheKey: string) { tasks.forget(cacheKey); }

// The app allows 200 seconds per Studio request. Leave time for upload and
// settlement instead of spending the entire request waiting for Kling.
const IMAGE_WORK_BUDGET_MS = 180_000;

/** Best-effort resumption until durable jobs are approved; never a background job. */
export async function composeScene(subject: ImageBlob, scene: StudioScene, cacheKey: string): Promise<ImageBlob> {
  const client = new KlingImageClient();
  const deadline = Date.now() + IMAGE_WORK_BUDGET_MS;
  const inputHash = createHash("sha256").update(subject.data).update(JSON.stringify(scene))
    .update(process.env.KLING_IMAGE_MODEL ?? "kling-v2-1").digest("hex");
  const cached = tasks.getOrSubmit(cacheKey, inputHash, () => client.submit(subject, scene));
  let taskId: string;
  try {
    ({ taskId } = await cached.submission);
  } catch (err) {
    // Keep unknown submissions: the provider may have accepted the paid task.
    // A definite rejection or missing credentials can be retried after fixing it.
    if (!(err instanceof ImageError) || !err.submissionUnknown) tasks.forget(cacheKey, cached);
    throw err;
  }
  while (Date.now() < deadline) {
    const boundedClient = new KlingImageClient({ requestTimeoutMs: Math.min(20_000, deadline - Date.now()) });
    const task = await boundedClient.status(taskId);
    if (task.status === "completed") {
      const remaining = deadline - Date.now();
      if (remaining <= 0) break;
      return new KlingImageClient({ downloadTimeoutMs: Math.min(20_000, remaining) }).download(task.url);
    }
    if (task.status === "failed") {
      tasks.forget(cacheKey, cached);
      throw new ImageError("Image generation failed. No credits were charged for this image.", true,
        { phase: "status", taskId });
    }
    await new Promise((resolve) => setTimeout(resolve, Math.max(0, Math.min(2_000, deadline - Date.now()))));
  }
  // A local wait deadline does not cancel Kling. Do not encourage a second
  // billable submission when the first one may still be rendering.
  throw new ImageError("The image is still processing. Completed images are saved; try this style again later to check progress.", true,
    { phase: "wait", taskId });
}
