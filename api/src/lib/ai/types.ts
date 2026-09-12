// The provider protocol (SPEC §3: image generation lives "Behind a protocol").
//
// Nothing in the feature code talks to Claude or Kling directly. It talks to
// these interfaces, so a provider can be swapped without touching product
// logic — and so the same logic can serve a future Android app and the bulk API.
//
// Every call returns `ModelUsage` alongside its result, because SPEC §9 requires
// a `generations` row for each one: "Always write `actual_cost_usd` — I need
// real margin numbers, not estimates."

/** Exactly what a `generations` row needs (SPEC §9). */
export interface ModelUsage {
  provider: "anthropic" | "kling";
  model: string;
  inputTokens: number;
  outputTokens: number;
  /** Served from the prompt cache — billed at a fraction of the input rate. */
  cachedInputTokens: number;
  /** Computed from the real token counts, never estimated up front. */
  costUSD: number;
  latencyMs: number;
  /** `langfuse_trace_id`. Null only when tracing itself failed. */
  traceId: string | null;
}

export interface ModelResult<T> {
  value: T;
  usage: ModelUsage;
}

// ── Vision: read a product photo ─────────────────────────────────────────────

export interface ProductPhoto {
  /** The on-device cutout (PNG with alpha), not the original frame (SPEC §4.1). */
  bytes: Uint8Array;
  mediaType: "image/png" | "image/jpeg" | "image/webp";
}

/**
 * What the model could actually see. Everything here must be observable in the
 * photo — a provider that invents a material or a brand name is a defect, not
 * a creative flourish.
 */
export interface ProductFacts {
  suggestedName: string;
  /** Marketplace-style path, e.g. "Home & Kitchen › Coffee". */
  suggestedCategory: string;
  material?: string;
  colour?: string;
  keyFeatures: string[];
  /**
   * Text legible on the product or its packaging, transcribed verbatim.
   *
   * Kept because SPEC §8 makes packaging fidelity a hard quality bar: recording
   * what the label says lets a later composite be checked against it.
   */
  visibleText: string[];
}

export interface VisionProvider {
  readProduct(photo: ProductPhoto): Promise<ModelResult<ProductFacts>>;
}

// ── Text: listing copy and ad scripts ────────────────────────────────────────

export interface AdScript {
  /** The first three seconds. TikTok lives or dies here (SPEC §2). */
  hook: string;
  beats: string[];
  durationSeconds: number;
}

export interface ScriptProvider {
  writeAdScripts(input: {
    facts: ProductFacts;
    marketplace: string;
    count: number;
  }): Promise<ModelResult<AdScript[]>>;
}

// ── Images: BACKGROUNDS ONLY ─────────────────────────────────────────────────

/**
 * A scene to render behind the product.
 *
 * There is deliberately no field for the product photo. SPEC §8:
 *
 *   1. Segment on device.  2. Generate background/scene ONLY.
 *   3. Composite the original, unmodified product pixels onto it.
 *
 * Handing the product to a generative model is how packaging text gets
 * rewritten and sellers get delisted. The interface makes that impossible to
 * do by accident.
 */
export interface BackgroundRequest {
  /** Describes the scene. Must never describe the product. */
  scenePrompt: string;
  negativePrompt?: string;
  aspectRatio: string;
  widthPx: number;
  heightPx: number;
}

export interface GeneratedBackground {
  bytes: Uint8Array;
  mediaType: string;
  widthPx: number;
  heightPx: number;
}

export interface BackgroundProvider {
  generateBackground(request: BackgroundRequest): Promise<ModelResult<GeneratedBackground>>;
}

// ── Failures ─────────────────────────────────────────────────────────────────

/**
 * A provider call that failed.
 *
 * `retryable` decides whether the job runs again; `charged` stays false so the
 * caller never bills for a failed generation — SPEC §6: "Check balance before
 * dispatching a generation, charge on success only."
 */
export class ProviderError extends Error {
  constructor(
    readonly provider: ModelUsage["provider"],
    message: string,
    readonly retryable: boolean,
    readonly cause?: unknown,
  ) {
    super(message);
    this.name = "ProviderError";
  }

  readonly charged = false;
}
