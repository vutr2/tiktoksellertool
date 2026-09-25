// validate(asset, rules) -> every violation, not just the first.
//
// Returning all of them is a deliberate UX decision: a seller who fixes one
// problem, re-runs, and is handed the next one has to make five round trips for
// five problems. They get the whole list at once instead.
//
// Messages here are shown to the seller verbatim (SPEC §10: "the rule named in
// plain English"), so they never contain a code, a field path, or jargon.

import type {
  Asset,
  ComplianceStatus,
  DescriptionAsset,
  ImageAsset,
  ImageRule,
  MarketplaceRules,
  TitleAsset,
  Violation,
} from "./types";

/** Our tolerance for floating-point ratio comparison, not a marketplace rule. */
const ASPECT_TOLERANCE = 0.01;

/**
 * The language every word list below is written in.
 *
 * The engine's keyword checks are English literals. Copy in another language
 * cannot match them, so it would come back clean without having been read —
 * the silent degradation SPEC §7 rules out. Callers pass the language of the
 * text so the engine can say so out loud instead.
 */
const CONTENT_LANGUAGE = "en";

/**
 * Character counts are taken on the composed form.
 *
 * "Máy pha cà phê" is 14 characters composed and 17 decomposed, and nothing
 * guarantees which form a model or a keyboard produces. Counting the raw
 * string would fail a title over how its accents happen to be encoded rather
 * than over its length.
 */
function nfc(text: string): string {
  return text.normalize("NFC");
}

/**
 * Wording that reads as promotion rather than description. A heuristic, not a
 * published list — flagged for review at the end of the milestone.
 */
const PROMO_PHRASES = [
  "best seller", "bestseller", "best price", "#1", "number one",
  "free shipping", "sale", "discount", "cheap", "lowest price",
  "money back", "guarantee", "hot deal", "limited time", "buy now",
];

/** A title is shouting only when it has real length and no lowercase at all. */
const ALL_CAPS_MIN_LETTERS = 8;

export function validate(asset: Asset, rules: MarketplaceRules, language: string = CONTENT_LANGUAGE): Violation[] {
  switch (asset.type) {
    case "image":
      return validateImage(asset, rules);
    case "title":
      return validateTitle(asset, rules, language);
    case "description":
      return validateDescription(asset, rules);
    case "script":
      // No marketplace script rules are modelled yet; saying "pass" would be a
      // lie, but there is nothing to check either.
      return [];
  }
}

/** The badge shown in Review. Worst severity present wins. */
export function statusOf(violations: Violation[]): ComplianceStatus {
  if (violations.some((v) => v.severity === "fail")) return "fail";
  if (violations.length > 0) return "warn";
  return "pass";
}

// ── Images ───────────────────────────────────────────────────────────────────

function validateImage(asset: ImageAsset, rules: MarketplaceRules): Violation[] {
  const rule = rules.images?.[asset.slot];
  if (!rule) return [];

  const name = rules.displayName;
  const slotLabel = asset.slot === "main" ? "main image" : "secondary image";
  const { facts } = asset;
  const violations: Violation[] = [];
  const field = `images.${asset.slot}`;

  // Aspect ratio
  if (rule.aspectRatio) {
    const required = parseRatio(rule.aspectRatio);
    const actual = facts.widthPx / facts.heightPx;
    const tolerance = rule.aspectTolerance ?? ASPECT_TOLERANCE;
    if (required !== null && Math.abs(actual - required) > tolerance) {
      violations.push({
        code: "image.aspect_ratio",
        severity: "fail",
        field: `${field}.aspectRatio`,
        message: `${name} requires a ${rule.aspectRatio} ${slotLabel}.`,
        detail: `This image is ${facts.widthPx}×${facts.heightPx}.`,
      });
    }
  }

  // Resolution
  const longestEdge = Math.max(facts.widthPx, facts.heightPx);
  if (rule.minLongestEdge !== undefined && longestEdge < rule.minLongestEdge) {
    violations.push({
      code: "image.too_small",
      severity: "fail",
      field: `${field}.minLongestEdge`,
      message: `${name} needs the ${slotLabel} to be at least ${rule.minLongestEdge}px on its longest side.`,
      detail: `This image is ${facts.widthPx}×${facts.heightPx}.`,
    });
  }
  if (rule.maxLongestEdge !== undefined && longestEdge > rule.maxLongestEdge) {
    violations.push({
      code: "image.too_large",
      severity: "fail",
      field: `${field}.maxLongestEdge`,
      message: `${name} caps the ${slotLabel} at ${rule.maxLongestEdge}px on its longest side.`,
      detail: `This image is ${facts.widthPx}×${facts.heightPx}.`,
    });
  }

  // Background
  if (rule.background?.mustBePureWhite) {
    const expected = rule.background.rgb ?? [255, 255, 255];
    const tolerance = rule.background.tolerance ?? 0;
    if (!facts.backgroundRGB) {
      violations.push({
        code: "image.background.unknown",
        severity: "warn",
        field: `${field}.background`,
        message: `We could not confirm the background is pure white, which ${name} requires on the ${slotLabel}.`,
        detail: "The background colour has not been measured yet.",
      });
    } else if (!withinTolerance(facts.backgroundRGB, expected, tolerance)) {
      const [r, g, b] = facts.backgroundRGB;
      violations.push({
        code: "image.background.not_white",
        severity: "fail",
        field: `${field}.background`,
        message: `${name} requires a pure white background on the ${slotLabel}.`,
        detail: `This background is RGB ${r}/${g}/${b}.`,
      });
    }
  }

  // How much of the frame the product fills
  const fill = rule.productFillRatio;
  if (fill) {
    if (facts.productFillRatio === undefined) {
      violations.push({
        code: "image.fill.unknown",
        severity: "warn",
        field: `${field}.productFillRatio`,
        message: `We could not confirm how much of the frame the product fills.`,
        detail: `${name} expects at least ${percent(fill.min)}.`,
      });
    } else {
      if (fill.min !== undefined && facts.productFillRatio < fill.min) {
        violations.push({
          code: "image.fill.too_small",
          severity: "fail",
          field: `${field}.productFillRatio`,
          message: `${name} expects the product to fill at least ${percent(fill.min)} of the ${slotLabel}.`,
          detail: `It currently fills ${percent(facts.productFillRatio)}.`,
        });
      }
      if (fill.max !== undefined && facts.productFillRatio > fill.max) {
        violations.push({
          code: "image.fill.too_large",
          severity: "fail",
          field: `${field}.productFillRatio`,
          message: `${name} expects the product to fill no more than ${percent(fill.max)} of the ${slotLabel}.`,
          detail: `It currently fills ${percent(facts.productFillRatio)}.`,
        });
      }
    }
  }

  // Forbidden content
  const forbid = rule.forbid ?? [];
  if (forbid.length > 0) {
    if (facts.contains === undefined) {
      // Not analysed is not the same as clean. Saying "pass" here is exactly
      // the silent degradation SPEC §7 forbids.
      violations.push({
        code: "image.content.unknown",
        severity: "warn",
        field: `${field}.forbid`,
        message: `This image has not been checked for things ${name} does not allow on the ${slotLabel}.`,
        detail: `${name} forbids: ${forbid.map(contentLabel).join(", ")}.`,
      });
    } else {
      for (const item of forbid) {
        if (facts.contains.includes(item)) {
          violations.push({
            code: `image.content.${item}`,
            severity: "fail",
            field: `${field}.forbid`,
            message: `${name} does not allow ${contentLabel(item)} on the ${slotLabel}.`,
          });
        }
      }
    }
  }

  return violations;
}

// ── Title ────────────────────────────────────────────────────────────────────

function validateTitle(asset: TitleAsset, rules: MarketplaceRules, language: string = CONTENT_LANGUAGE): Violation[] {
  const rule = rules.title;
  if (!rule) return [];

  const name = rules.displayName;
  const text = nfc(asset.text);
  const violations: Violation[] = [];

  if (rule.maxChars !== undefined && text.length > rule.maxChars) {
    violations.push({
      code: "title.too_long",
      severity: "fail",
      field: "title.maxChars",
      message: `${name} allows ${rule.maxChars} characters in a title.`,
      detail: `This title is ${text.length} characters — ${text.length - rule.maxChars} over.`,
    });
  }
  if (rule.minChars !== undefined && text.length < rule.minChars) {
    violations.push({
      code: "title.too_short",
      severity: "warn",
      field: "title.minChars",
      message: `${name} expects at least ${rule.minChars} characters in a title.`,
      detail: `This title is ${text.length} characters.`,
    });
  }

  const forbid = rule.forbid ?? [];
  if (forbid.includes("allCaps") && isAllCaps(text)) {
    violations.push({
      code: "title.all_caps",
      severity: "fail",
      field: "title.forbid",
      message: `${name} does not allow titles in all capitals.`,
    });
  }
  if (forbid.includes("promoLanguage")) {
    // The list is still run: English promotional wording turns up in
    // non-English copy often enough to be worth catching.
    const found = PROMO_PHRASES.filter((phrase) => text.toLowerCase().includes(phrase));
    if (found.length > 0) {
      violations.push({
        code: "title.promo_language",
        severity: "warn",
        field: "title.forbid",
        message: `${name} does not allow promotional wording in a title.`,
        detail: `Found: ${found.join(", ")}.`,
      });
    } else if (language !== CONTENT_LANGUAGE) {
      violations.push({
        code: "title.promo_language.unchecked",
        severity: "warn",
        field: "title.forbid",
        message: `We could not check this title for promotional wording, which ${name} does not allow.`,
        detail: "Our wording list only covers English. Read this title yourself before you publish it.",
      });
    }
  }

  return violations;
}

// ── Description ──────────────────────────────────────────────────────────────

function validateDescription(asset: DescriptionAsset, rules: MarketplaceRules): Violation[] {
  const rule = rules.description;
  if (!rule) return [];

  const name = rules.displayName;
  const violations: Violation[] = [];

  if (rule.format === "bullets") {
    const bullets = asset.bullets;
    if (!bullets) {
      violations.push({
        code: "description.wrong_format",
        severity: "fail",
        field: "description.format",
        message: `${name} expects the description as bullet points.`,
        detail: "This description is a single block of text.",
      });
      return violations;
    }
    if (rule.maxBullets !== undefined && bullets.length > rule.maxBullets) {
      violations.push({
        code: "description.too_many_bullets",
        severity: "fail",
        field: "description.maxBullets",
        message: `${name} allows ${rule.maxBullets} bullet points.`,
        detail: `This description has ${bullets.length}.`,
      });
    }
    if (rule.maxCharsPerBullet !== undefined) {
      bullets.forEach((bullet, index) => {
        if (nfc(bullet).length > rule.maxCharsPerBullet!) {
          violations.push({
            code: "description.bullet_too_long",
            severity: "fail",
            field: "description.maxCharsPerBullet",
            message: `${name} allows ${rule.maxCharsPerBullet} characters per bullet point.`,
            detail: `Bullet ${index + 1} is ${nfc(bullet).length} characters.`,
          });
        }
      });
    }
  }

  if (rule.maxChars !== undefined) {
    const length = nfc(asset.text ?? (asset.bullets ?? []).join("\n")).length;
    if (length > rule.maxChars) {
      violations.push({
        code: "description.too_long",
        severity: "fail",
        field: "description.maxChars",
        message: `${name} allows ${rule.maxChars} characters in a description.`,
        detail: `This description is ${length} characters.`,
      });
    }
  }

  return violations;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function parseRatio(ratio: string): number | null {
  const [w, h] = ratio.split(":").map(Number);
  if (!Number.isFinite(w) || !Number.isFinite(h) || h === 0) return null;
  return w / h;
}

function withinTolerance(
  actual: [number, number, number],
  expected: [number, number, number],
  tolerance: number,
): boolean {
  return actual.every((channel, i) => Math.abs(channel - expected[i]) <= tolerance);
}

/** Shouting only counts when the title has real length and no lowercase at all. */
function isAllCaps(text: string): boolean {
  const letters = text.replace(/[^\p{L}]/gu, "");
  if (letters.length < ALL_CAPS_MIN_LETTERS) return false;
  return letters === letters.toUpperCase() && letters !== letters.toLowerCase();
}

function percent(value: number | undefined): string {
  return value === undefined ? "—" : `${Math.round(value * 100)}%`;
}

function contentLabel(item: string): string {
  switch (item) {
    case "text": return "overlay text";
    case "logo": return "logos";
    case "watermark": return "watermarks";
    case "border": return "borders";
    case "human": return "people";
    default: return item;
  }
}
