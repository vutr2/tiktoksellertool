// Studio images: generate the BACKGROUND ONLY, then composite the seller's
// real cutout on top (SPEC §8). A diffusion model like Kling redraws whatever
// reference it is given — a photographed water bottle came back as a Red Bull
// can — so the product is NEVER sent to it. The original product pixels are
// pasted over the generated scene here, preserving the label exactly.

import sharp from "sharp";
import { kling } from "../env.ts";
import { type StudioScene } from "../studio.ts";
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

  // `subject` is intentionally unused: the product is never sent to Kling. It
  // stays in the signature so callers (and tests) pass the same arguments.
  async submit(subject: ImageBlob, scene: StudioScene): Promise<{ taskId: string; model: string }> {
    void subject;
    const model = process.env.KLING_IMAGE_MODEL ?? "kling-v2-1";
    // Text-to-image of the EMPTY scene only. No reference image, so nothing to
    // redraw; the real product is composited on afterwards.
    const json = await this.call("POST", "/v1/images/generations", {
      model_name: model,
      prompt: backgroundPrompt(scene),
      negative_prompt: backgroundNegative(scene),
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
      const background = await new KlingImageClient({ downloadTimeoutMs: Math.min(20_000, remaining) }).download(task.url);
      // Paste the real product over the generated scene — this is what keeps
      // the label pixel-accurate instead of a hallucinated look-alike.
      return compositeProduct(subject, background);
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

// The product must NOT appear in the generated scene — it is composited on
// afterwards. These push the model toward an empty studio surface/backdrop.
function backgroundPrompt(scene: StudioScene): string {
  return `${scene.prompt}\n\nRender ONLY the empty scene and background: the surface, lighting and setting, with clear empty space in the centre where a product will be placed later. Do not draw any product, bottle, can, jar, box, package or item.`;
}

function backgroundNegative(scene: StudioScene): string {
  return `${scene.negative}, product, bottle, can, jar, box, package, item, object in centre, foreground subject, text, label`;
}

/**
 * Composite the seller's cutout (PNG with alpha) onto the generated scene,
 * centred and resting slightly below centre so it reads as sitting on the
 * surface. sharp keeps the product pixels exactly as photographed.
 */
async function compositeProduct(subject: ImageBlob, background: ImageBlob): Promise<ImageBlob> {
  try {
    const bg = sharp(background.data);
    const meta = await bg.metadata();
    const width = meta.width ?? 1024;
    const height = meta.height ?? 1024;
    // Fit the product to ~68% of the shorter edge, preserving its aspect.
    const target = Math.round(Math.min(width, height) * 0.68);
    const product = await sharp(subject.data)
      .resize({ width: target, height: target, fit: "inside", withoutEnlargement: false })
      .png()
      .toBuffer();
    const pm = await sharp(product).metadata();
    const left = Math.round((width - (pm.width ?? target)) / 2);
    const top = Math.round((height - (pm.height ?? target)) * 0.58);
    const out = await bg
      .composite([{ input: product, left: Math.max(0, left), top: Math.max(0, top) }])
      .jpeg({ quality: 90 })
      .toBuffer();
    return { data: out, mime: "image/jpeg" };
  } catch {
    // Compositing failure must not lose the paid render; return the scene as-is.
    return background;
  }
}
