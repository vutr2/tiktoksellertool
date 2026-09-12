// The rules engine's vocabulary.
//
// Design decision that shapes everything here: the engine is PURE. It never
// touches pixels. It takes *measured facts* about an asset and applies a
// declarative rule set to them. Measurement (Vision on device, analysis on the
// server) happens elsewhere and lands in `facts`.
//
// That split is what makes the engine deterministic, testable against fixtures
// with no image processing, and reusable by a future Android app and the bulk
// API — which SPEC §7 requires.

export type MarketplaceId = "tiktok_shop" | "amazon" | "ebay" | "etsy";

export type AssetType = "image" | "title" | "description" | "script";

/** Rules differ sharply between the two slots; Amazon's main image is strict. */
export type ImageSlot = "main" | "secondary";

/** Things a rule set can forbid in an image. */
export type ImageContent = "text" | "logo" | "watermark" | "border" | "human";

// ── Rule configuration ───────────────────────────────────────────────────────
// Served as versioned JSON so limits can change without an App Store review
// (SPEC §7). Any object may carry `TODO_VERIFY: true`, meaning the numbers in it
// are scaffolding awaiting the real marketplace spec.

export interface Unverifiable {
  /** Present and true while the values here are unconfirmed. */
  TODO_VERIFY?: true;
  /** Where the confirmed value should come from. */
  source?: string;
}

export interface BackgroundRule extends Unverifiable {
  mustBePureWhite?: boolean;
  rgb?: [number, number, number];
  /** How far each channel may drift and still count as "pure" white. */
  tolerance?: number;
}

export interface ImageRule extends Unverifiable {
  /** "1:1", "4:5", "16:9" … Omitted means any ratio is allowed. */
  aspectRatio?: string;
  /** Tolerance on the ratio, as a fraction. 0.01 = 1%. */
  aspectTolerance?: number;
  minLongestEdge?: number;
  maxLongestEdge?: number;
  background?: BackgroundRule;
  productFillRatio?: { min?: number; max?: number };
  forbid?: ImageContent[];
}

export interface TitleRule extends Unverifiable {
  maxChars?: number;
  minChars?: number;
  forbid?: ("allCaps" | "promoLanguage")[];
}

export interface DescriptionRule extends Unverifiable {
  format?: "bullets" | "paragraph";
  maxBullets?: number;
  maxCharsPerBullet?: number;
  maxChars?: number;
}

export interface MarketplaceRules {
  id: MarketplaceId;
  /** Bumped whenever a limit changes, so the device cache can be invalidated. */
  version: string;
  displayName: string;
  /** Which plan unlocks it — drives the Pro badge in the marketplace picker. */
  tier: "included" | "pro";
  /** One line shown under the name in the picker. */
  summary: string;
  images: Partial<Record<ImageSlot, ImageRule>>;
  title?: TitleRule;
  description?: DescriptionRule;
}

// ── Assets ───────────────────────────────────────────────────────────────────

/**
 * What analysis measured about an image.
 *
 * `contains` being undefined means "not analysed yet" — which is NOT the same
 * as "contains nothing". validate() reports the difference instead of quietly
 * passing an image nobody has looked at.
 */
export interface ImageFacts {
  widthPx: number;
  heightPx: number;
  /** Dominant background colour; omit when the background is not uniform. */
  backgroundRGB?: [number, number, number];
  /** Share of the frame the product occupies, 0–1. */
  productFillRatio?: number;
  /** Everything detected in the frame. Empty array = analysed, found nothing. */
  contains?: ImageContent[];
}

export interface ImageAsset {
  type: "image";
  slot: ImageSlot;
  facts: ImageFacts;
}

export interface TitleAsset {
  type: "title";
  text: string;
}

export interface DescriptionAsset {
  type: "description";
  /** Bullet marketplaces populate this; paragraph ones use `text`. */
  bullets?: string[];
  text?: string;
}

export interface ScriptAsset {
  type: "script";
  text: string;
}

export type Asset = ImageAsset | TitleAsset | DescriptionAsset | ScriptAsset;

// ── Results ──────────────────────────────────────────────────────────────────

/** `fail` blocks the listing; `warn` is worth a look but will not get it removed. */
export type Severity = "fail" | "warn";

/** The badge shown per asset in Review (SPEC §10 step 5). */
export type ComplianceStatus = "pass" | "warn" | "fail";

export interface Violation {
  /** Stable machine id, e.g. "image.background.not_white". */
  code: string;
  severity: Severity;
  /** Dotted path into the rule set, e.g. "images.main.background". */
  field: string;
  /** Plain English, shown to the seller verbatim. Never jargon, never a code. */
  message: string;
  /** Optional second line with the specifics. */
  detail?: string;
}

/** One thing convert() actually did. Mirrors the "What changed" list. */
export interface Change {
  code: string;
  summary: string;
  detail: string;
  /**
   * `applied` — done, nothing further needed.
   * `needs_review` — we acted, but a human should confirm the outcome.
   */
  status: "applied" | "needs_review";
}

export interface ConversionResult {
  from: MarketplaceId;
  to: MarketplaceId;
  changes: Change[];
  /**
   * What could NOT be fixed automatically. SPEC §7: never silently "fix" by
   * degrading — anything we cannot honestly resolve is reported here.
   */
  unresolved: Violation[];
  /** True when a fix needs the image generated again, which costs credits. */
  requiresRerender: boolean;
  /** 0 when no re-render is needed — conversion is deliberately free (SPEC §6). */
  creditCost: number;
}
