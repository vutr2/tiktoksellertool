// Per-industry listing knowledge, ported (in English) from tiktok_tools'
// prompt packs. Two jobs:
//   1. `voice` + `hashtagGuidance` steer the listing model.
//   2. `bannedClaims` run BOTH ways — injected into the prompt to avoid, and
//      re-scanned over the output to catch what the model wrote anyway.
//
// Adding an industry = one entry here. Pure module (no SDK), so it is testable.

import type { Industry } from "./studio.ts";

export type BannedClaim = {
  /** Case-insensitive regex source matching the phrase not allowed. */
  pattern: string;
  why: string;
  fix: string;
};

export type IndustryPack = {
  voice: string;
  /** One line telling the model how to pick hashtags for this industry. */
  hashtagGuidance: string;
  bannedClaims: BannedClaim[];
};

// English word boundaries are enough here (unlike the Vietnamese source).
const b = (phrase: string) => `\\b${phrase}\\b`;

const COMPETITOR_BRANDS = "(zara|h&m|nike|adidas|gucci|chanel|dior|louis vuitton|uniqlo|shein)";

export const INDUSTRY_PACKS: Record<Industry, IndustryPack> = {
  BEAUTY: {
    voice: "Talk like someone who has actually used it. Describe how it feels on the skin (absorbs fast, slight tingle at first, not sticky) before ingredients. Give concrete concentrations instead of adjectives.",
    hashtagGuidance: "Mix broad (#skincare) and specific (#niacinamide, #oilyskin) tags; no medical claims in tags.",
    bannedClaims: [
      { pattern: b("(cure|cures|treats?|heals?)\\s+(acne|eczema|rosacea|scars?)"),
        why: "Cosmetics cannot be advertised as drugs; marketplaces delist and regulators fine this.",
        fix: 'Use "helps reduce", "soothes", or "improves the look of".' },
      { pattern: "\\b(guaranteed|permanent(?:ly)?|forever)\\b|100\\s*%",
        why: "Absolute promises are false advertising.",
        fix: 'State conditional results: "after 4 weeks of consistent use, most people see...".' },
      { pattern: b("(safe for everyone|no side effects|completely safe)"),
        why: "No product can prove this.",
        fix: 'Say "patch-tested", "fragrance-free", or "suitable for sensitive skin".' },
    ],
  },
  FASHION: {
    voice: "Sell the fit and the fabric. Name the material and the size range up front; describe drape and occasion. Honest about stretch and thickness.",
    hashtagGuidance: "Use style/occasion tags (#ootd, #workwear) plus item type; avoid other brands' names.",
    bannedClaims: [
      { pattern: b(COMPETITOR_BRANDS),
        why: "Using another brand's name suggests affiliation or counterfeit.",
        fix: "Remove the brand name; describe the style instead (e.g. 'minimalist', 'streetwear')." },
      { pattern: b("(freesize|one size fits all)"),
        why: "'Free size' without a measurement range causes returns and disputes.",
        fix: "Give the actual measurements or weight range it fits." },
      { pattern: b("(genuine|real)\\s+(leather|silk)"),
        why: "Material authenticity claims need proof and are often wrong.",
        fix: "State the exact composition (e.g. 'PU leather', '95% cotton')." },
    ],
  },
  HOME: {
    voice: "Lead with the practical benefit and the spec (capacity, material, wattage). Concrete and reassuring; no hype.",
    hashtagGuidance: "Use room/use-case tags (#kitchen, #homeorganization) plus the product type.",
    bannedClaims: [
      { pattern: b("(kills?|eliminates?)\\s+(99\\.?9%|all)\\s+(germs|bacteria|viruses)"),
        why: "Disinfection percentages need lab certification.",
        fix: "Drop the number or cite the test standard you actually hold." },
      { pattern: b("lifetime\\s+(warranty|guarantee)"),
        why: "A lifetime warranty is rarely enforceable and invites disputes.",
        fix: "State the real period, e.g. '12-month replacement'." },
      { pattern: b("(medical|hospital)\\s+grade"),
        why: "Implies a certification most home goods do not hold.",
        fix: "Describe the material honestly (e.g. 'food-grade stainless steel')." },
    ],
  },
  BABY_KIDS: {
    voice: "Reassure parents. Lead with age suitability, material safety and certification. Calm, precise, never alarmist.",
    hashtagGuidance: "Use age/parenting tags (#newborn, #momlife) plus the item; never medical claims.",
    bannedClaims: [
      { pattern: b("(cures?|prevents?|treats?)\\s+\\w+"),
        why: "Medical claims on baby products are heavily restricted.",
        fix: "Describe the feature, not a health outcome." },
      { pattern: b("(100%\\s+safe|completely safe|non-?toxic guaranteed)"),
        why: "Absolute safety claims cannot be substantiated.",
        fix: "Cite the certification (e.g. 'OEKO-TEX certified', 'CPSIA compliant')." },
      { pattern: b("(breast\\s*milk\\s+(substitute|replacement)|replaces breast milk)"),
        why: "Infant-nutrition claims are tightly regulated in most markets.",
        fix: "Remove the claim; do not compare to breast milk." },
    ],
  },
  ACCESSORIES: {
    voice: "Lead with compatibility and the standout spec. Concrete about materials and protection level.",
    hashtagGuidance: "Use device/use tags (#iphone15, #techaccessories); avoid implying official brand licensing.",
    bannedClaims: [
      { pattern: b("waterproof"),
        why: "Most cases are only water-resistant; 'waterproof' invites refund claims.",
        fix: "Say 'water-resistant' with the rating (e.g. IP67) if you have it." },
      { pattern: b("(apple|samsung|google)\\s+(certified|official)"),
        why: "Implies official licensing (e.g. MFi) you may not hold.",
        fix: "Say 'compatible with' instead of 'certified'." },
      { pattern: b("(unbreakable|indestructible|military\\s+grade)"),
        why: "Absolute durability claims are false advertising unless tested.",
        fix: "State the tested drop height (e.g. 'tested to 2m drops')." },
    ],
  },
};

export type LintHit = { matched: string; why: string; fix: string };

/** Scan generated text for this industry's banned phrases. */
export function lintClaims(text: string, industry: Industry): LintHit[] {
  const hits: LintHit[] = [];
  for (const claim of INDUSTRY_PACKS[industry].bannedClaims) {
    const matches = text.match(new RegExp(claim.pattern, "gi"));
    if (matches && matches.length > 0) {
      hits.push({ matched: [...new Set(matches.map((m) => m.trim()))].join(", "), why: claim.why, fix: claim.fix });
    }
  }
  return hits;
}
