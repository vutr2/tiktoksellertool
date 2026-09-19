// Studio image compositing via Kling. Ported (in English) from tiktok_tools.
//
// Kling is a diffusion model, so it REDRAWS. Product photos live or die on the
// label staying intact, which is why `image_fidelity` is high and the prompt
// hammers "keep the product identical" (see PRESERVE_PRODUCT). Kling is already
// this project's image provider — reuse its env, do not add a second vendor.
//
// Three Kling quirks handled here:
//   1. Async — POST creates a task, then poll until it finishes.
//   2. Returns an image URL, not base64 — download to a Buffer.
//   3. No usage/token accounting — cost is not derivable per call.

import { kling } from "@/lib/env";
import { PRESERVE_PRODUCT, type StudioScene } from "@/lib/studio";

export class ImageError extends Error {
  readonly retryable: boolean;
  constructor(message: string, retryable = true) {
    super(message);
    this.name = "ImageError";
    this.retryable = retryable;
  }
}

export type ImageBlob = { data: Buffer; mime: string };

/** Kling does not accept "4:5"; fold it to the nearest portrait ratio. */
const KLING_ASPECT: Record<string, string> = {
  "1:1": "1:1", "4:5": "3:4", "3:4": "3:4", "9:16": "9:16", "16:9": "16:9",
};

const POLL_MS = 2_000;
const TIMEOUT_MS = 170_000;

type KlingTask = {
  code?: number;
  message?: string;
  data?: {
    task_id?: string;
    task_status?: string;
    task_status_msg?: string;
    task_result?: { images?: { url?: string }[] };
  };
};

function model(): string {
  return process.env.KLING_IMAGE_MODEL ?? "kling-v2-1";
}

/** Composite the product cutout onto the scene's studio backdrop. */
export async function composeScene(subject: ImageBlob, scene: StudioScene): Promise<ImageBlob> {
  const taskId = await createTask({
    prompt: `${scene.prompt}\n\n${PRESERVE_PRODUCT}`,
    negative: scene.negative,
    aspect: KLING_ASPECT[scene.aspect] ?? "1:1",
    subject,
  });
  const url = await awaitImage(taskId);
  return download(url);
}

async function createTask(args: {
  prompt: string;
  negative: string;
  aspect: string;
  subject: ImageBlob;
}): Promise<string> {
  const json = await call<KlingTask>("POST", "/v1/images/generations", {
    model_name: model(),
    prompt: args.prompt,
    negative_prompt: args.negative,
    image: args.subject.data.toString("base64"),
    // "subject" makes Kling hold on to the product in the reference image
    // rather than only borrowing its layout.
    image_reference: "subject",
    image_fidelity: 0.9,
    aspect_ratio: args.aspect,
    n: 1,
  });
  const id = json.data?.task_id;
  if (!id) throw new ImageError(`Could not start image generation: ${json.message ?? "unknown"}`);
  return id;
}

async function awaitImage(taskId: string): Promise<string> {
  const deadline = Date.now() + TIMEOUT_MS;
  while (Date.now() < deadline) {
    const json = await call<KlingTask>("GET", `/v1/images/generations/${taskId}`);
    const status = json.data?.task_status;
    if (status === "succeed") {
      const url = json.data?.task_result?.images?.[0]?.url;
      if (!url) throw new ImageError("Generation finished but returned no image.");
      return url;
    }
    if (status === "failed") {
      throw new ImageError(`Image generation failed: ${json.data?.task_status_msg ?? "unknown reason"}`);
    }
    await delay(POLL_MS);
  }
  throw new ImageError(`Image generation timed out after ${TIMEOUT_MS / 1000}s. Retry the same request.`);
}

async function download(url: string): Promise<ImageBlob> {
  const res = await fetch(url);
  if (!res.ok) throw new ImageError(`Could not download the generated image (${res.status}).`);
  return { data: Buffer.from(await res.arrayBuffer()), mime: res.headers.get("content-type") ?? "image/png" };
}

async function call<T extends KlingTask>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${kling.baseURL()}${path}`, {
      method,
      headers: { Authorization: `Bearer ${kling.apiKey()}`, "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch (err) {
    throw new ImageError(`Could not reach the image service: ${err instanceof Error ? err.message : String(err)}`);
  }
  const json = (await res.json().catch(() => null)) as T | null;
  if (!res.ok || (json?.code !== undefined && json.code !== 0)) {
    // 1102 = out of balance: not retryable, and the caller must refund credits.
    const retryable = json?.code !== 1102 && res.status !== 401 && res.status !== 403;
    throw new ImageError(`Image service error (${res.status}/${json?.code ?? "?"}): ${json?.message ?? "unknown"}`, retryable);
  }
  return json as T;
}

function delay(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
