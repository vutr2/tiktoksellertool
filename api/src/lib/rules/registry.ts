// Loads the marketplace rule sets and reports what in them is still unverified.

import amazon from "./configs/amazon.json" with { type: "json" };
import tiktokShop from "./configs/tiktok_shop.json" with { type: "json" };
import ebay from "./configs/ebay.json" with { type: "json" };
import etsy from "./configs/etsy.json" with { type: "json" };
import type { MarketplaceId, MarketplaceRules } from "./types";

// The JSON is authored by hand, so it is cast once here rather than at every
// call site. The test suite asserts the shape actually matches.
const REGISTRY: Record<MarketplaceId, MarketplaceRules> = {
  amazon: amazon as MarketplaceRules,
  tiktok_shop: tiktokShop as MarketplaceRules,
  ebay: ebay as MarketplaceRules,
  etsy: etsy as MarketplaceRules,
};

export const MARKETPLACE_IDS = Object.keys(REGISTRY) as MarketplaceId[];

export function rulesFor(id: MarketplaceId): MarketplaceRules {
  const rules = REGISTRY[id];
  if (!rules) throw new Error(`Unknown marketplace: ${id}`);
  return rules;
}

export function allRules(): MarketplaceRules[] {
  return MARKETPLACE_IDS.map(rulesFor);
}

/** A value still awaiting the real marketplace spec (SPEC §7). */
export interface PendingVerification {
  marketplace: MarketplaceId;
  /** Dotted path to the object carrying the flag. */
  path: string;
  source?: string;
}

/**
 * Walks every rule set and collects the `TODO_VERIFY` flags.
 *
 * This exists so the milestone can end with an honest list rather than a claim
 * that the limits are correct — none of them have been checked against a live
 * marketplace spec.
 */
export function pendingVerifications(): PendingVerification[] {
  const found: PendingVerification[] = [];

  function walk(node: unknown, marketplace: MarketplaceId, path: string): void {
    if (node === null || typeof node !== "object" || Array.isArray(node)) return;
    const record = node as Record<string, unknown>;
    if (record.TODO_VERIFY === true) {
      found.push({
        marketplace,
        path: path || "(root)",
        source: typeof record.source === "string" ? record.source : undefined,
      });
    }
    for (const [key, value] of Object.entries(record)) {
      if (key === "TODO_VERIFY" || key === "source") continue;
      walk(value, marketplace, path ? `${path}.${key}` : key);
    }
  }

  for (const rules of allRules()) walk(rules, rules.id, "");
  return found;
}
