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
  /**
   * Computed from the real token counts, never estimated up front.
   *
   * Null means the model's rate is unknown — it must stay null all the way to
   * `generations.actual_cost_usd`, which is nullable for exactly this reason.
   * Collapsing it to 0 would read as a free call and corrupt the margin
   * numbers SPEC §9 exists to protect.
   */
  costUSD: number | null;
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

/**
 * The language the seller wants their copy written in.
 *
 * Only generated prose is translated. Text transcribed from the product
 * (`ProductFacts.visibleText`) stays verbatim — translating a label is how a
 * listing stops matching what is actually in the box.
 */
export type OutputLanguage = "en" | "vi";

export interface AdScript {
  /** The first three seconds. TikTok lives or dies here (SPEC §2). */
  hook: string;
  beats: string[];
  durationSeconds: number;
}

/** A marketplace listing: the title and description for one marketplace. */
export interface ListingCopy {
  title: string;
  /** Bullet marketplaces populate this; paragraph ones use `description`. */
  bullets: string[];
  description?: string;
  /** Suggested hashtags (without the leading #). Empty when not requested. */
  hashtags: string[];
}

export interface ListingCopyProvider {
  writeListing(input: {
    facts: ProductFacts;
    marketplaceName: string;
    /** The marketplace's own limits, so the model aims inside them rather than
     *  being corrected afterwards. */
    constraints: {
      titleMaxChars?: number;
      bulletFormat: boolean;
      maxBullets?: number;
      maxCharsPerBullet?: number;
      forbidPromoLanguage: boolean;
      forbidAllCaps: boolean;
    };
    /** Optional per-industry selling voice to steer tone. */
    voice?: string;
    /** Optional guidance for how to choose hashtags; when set, ask for hashtags. */
    hashtagGuidance?: string;
    /** Short "avoid this / do that instead" hints from the industry pack. */
    avoid?: string[];
    /** Defaults to English when absent. */
    language?: OutputLanguage;
  }): Promise<ModelResult<ListingCopy>>;
}

export interface ScriptProvider {
  writeAdScripts(input: {
    facts: ProductFacts;
    marketplace: string;
    count: number;
    /** Defaults to English when absent. */
    language?: OutputLanguage;
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
  // Written out rather than declared as constructor parameter properties:
  // Node's type-stripping test runner rejects that syntax, and these types are
  // shared with the tests.
  readonly provider: ModelUsage["provider"];
  readonly retryable: boolean;
  readonly reason: unknown;
  readonly charged = false;

  constructor(
    provider: ModelUsage["provider"],
    message: string,
    retryable: boolean,
    reason?: unknown,
  ) {
    super(message);
    this.name = "ProviderError";
    this.provider = provider;
    this.retryable = retryable;
    this.reason = reason;
  }
}
