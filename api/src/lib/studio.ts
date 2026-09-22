// Studio scene packs — ported (in English) from tiktok_tools' per-industry
// `scenes`. Scene styling is subordinate to product identity. Kling backgrounds
// are composited locally; Grok edits are guided by preservation instructions
// and still need visual review (see ai/image.ts).
//
// Scenes are code, not data: editing a backdrop means editing a prompt, which
// goes through review — not a row in the database.

export const INDUSTRIES = ["BEAUTY", "FASHION", "HOME", "BABY_KIDS", "ACCESSORIES"] as const;
export type Industry = (typeof INDUSTRIES)[number];

export function isIndustry(v: unknown): v is Industry {
  return typeof v === "string" && (INDUSTRIES as readonly string[]).includes(v);
}

export type StudioScene = {
  id: string;
  name: string;
  emoji: string;
  /** Where the seller should use this shot — shown so they don't pick blindly. */
  useCase: string;
  /** Written in English: image models understand it better. */
  prompt: string;
  negative: string;
  aspect: "1:1" | "4:5" | "9:16";
};

/** Prompt guidance; only compositing original pixels can enforce preservation. */
export const PRESERVE_PRODUCT =
  "The supplied product is the source of truth. Preserve its identity, silhouette, proportions, " +
  "pose, camera angle, colours, materials, texture, seams, closures and all visible components. " +
  "Keep every logo, label, letter, number and printed graphic exactly as supplied, including " +
  "placement, spelling and typography. Preserve existing highlights and surface details. " +
  "Do not redraw, retouch, recolour, reshape, relight, mirror or replace the product; do not " +
  "invent hidden sides, missing parts, packaging or accessories. Only move the complete product " +
  "and scale it uniformly to fit the composition. Adapt the environment to the product, not the product to the scene.";

const COMMON_NEGATIVE =
  "text overlay, watermark, extra products, human hands, cluttered props, harsh shadows, " +
  "blown highlights, distorted label, changed logo, warped product";

export const STUDIO_SCENES: Record<Industry, [StudioScene, StudioScene, StudioScene, StudioScene]> = {
  BEAUTY: [
    { id: "marble_podium", name: "Marble podium", emoji: "🪨",
      useCase: "Listing cover — clean and premium, reads well as a small thumbnail.",
      prompt: "Product photography on a white marble podium, soft diffused studio light from the upper left, subtle natural shadow to the lower right, clean off-white seamless background, faint reflection on the polished marble, minimal composition with generous negative space, high-end skincare catalogue aesthetic, sharp focus on the label, shot on 85mm lens f/4.",
      negative: COMMON_NEGATIVE, aspect: "1:1" },
    { id: "spa_stone", name: "Spa stones & water", emoji: "💧",
      useCase: "Lifestyle shot conveying gentle, clean, skin-loving.",
      prompt: "Product on smooth grey spa stones beside a shallow ripple of water, soft morning light, eucalyptus leaf out of focus in the background, calm wellness mood, muted natural palette.",
      negative: COMMON_NEGATIVE, aspect: "4:5" },
    { id: "silk_drape", name: "Silk drape", emoji: "🎀",
      useCase: "Luxury feel for a hero image or a promo banner.",
      prompt: "Product resting on a softly folded cream silk drape, warm glossy highlights, elegant boudoir lighting, shallow depth of field, luxury cosmetics editorial look.",
      negative: COMMON_NEGATIVE, aspect: "1:1" },
    { id: "vanity_shelf", name: "Vanity shelf", emoji: "🪞",
      useCase: "Show it in a real morning routine.",
      prompt: "Product on a minimalist vanity shelf near a bright window, soft daylight, a hint of a round mirror bokeh behind, fresh clean bathroom aesthetic, airy and light.",
      negative: COMMON_NEGATIVE, aspect: "9:16" },
  ],
  FASHION: [
    { id: "flat_lay", name: "Flat lay", emoji: "🧺",
      useCase: "Catalogue cover — keeps fabric texture and folds honest.",
      prompt: "Top-down flat lay of the garment on a neutral linen backdrop, even soft light, natural fabric folds, a few tasteful minimalist accessories at the edges, clean editorial fashion look.",
      negative: COMMON_NEGATIVE, aspect: "1:1" },
    { id: "street_wall", name: "Street wall", emoji: "🧱",
      useCase: "Trendy street-style vibe for TikTok.",
      prompt: "The garment styled against a sunlit textured concrete wall, urban street-style mood, warm late-afternoon light, soft shadow, candid lookbook aesthetic.",
      negative: COMMON_NEGATIVE, aspect: "9:16" },
    { id: "studio_seamless", name: "Studio seamless", emoji: "🎬",
      useCase: "Clean e-commerce standard shot.",
      prompt: "The garment on a smooth seamless pale grey studio backdrop, balanced softbox lighting from both sides, crisp true-to-life color, professional apparel product photography.",
      negative: COMMON_NEGATIVE, aspect: "4:5" },
    { id: "wood_hanger", name: "Wooden hanger", emoji: "🪵",
      useCase: "Boutique feel showing drape and shape.",
      prompt: "The garment on a wooden hanger against a warm beige wall, soft directional light showing the drape and silhouette, cozy boutique atmosphere.",
      negative: COMMON_NEGATIVE, aspect: "4:5" },
  ],
  HOME: [
    { id: "kitchen_wood", name: "Wooden countertop", emoji: "🪵",
      useCase: "Listing cover for kitchen and dining goods.",
      prompt: "Product on a minimalist light-wood kitchen countertop, bright natural window light, a soft blurred kitchen background, clean Scandinavian home aesthetic, gentle shadow.",
      negative: COMMON_NEGATIVE, aspect: "1:1" },
    { id: "living_room", name: "Cozy living room", emoji: "🛋️",
      useCase: "Show it living in a warm home.",
      prompt: "Product on a side table in a cozy living room, warm ambient light, out-of-focus sofa and plant behind, inviting lived-in mood, homely palette.",
      negative: COMMON_NEGATIVE, aspect: "4:5" },
    { id: "white_seamless", name: "White seamless", emoji: "⬜",
      useCase: "Clean spec shot for marketplace galleries.",
      prompt: "Product on a pure white seamless studio background, even shadowless lighting, crisp edges, true color, standard e-commerce catalogue photography.",
      negative: COMMON_NEGATIVE, aspect: "1:1" },
    { id: "shelf_styled", name: "Styled shelf", emoji: "📚",
      useCase: "Lifestyle context with tasteful props.",
      prompt: "Product styled on a wooden shelf with a few minimalist neutral props, soft daylight, balanced composition, modern home-decor editorial look.",
      negative: COMMON_NEGATIVE, aspect: "9:16" },
  ],
  BABY_KIDS: [
    { id: "pastel_soft", name: "Pastel softbox", emoji: "🎀",
      useCase: "Gentle listing cover parents trust.",
      prompt: "Product on a soft pastel seamless background, very soft diffused light, gentle rounded shadow, tender and clean baby-product aesthetic, calming palette.",
      negative: COMMON_NEGATIVE, aspect: "1:1" },
    { id: "cotton_blanket", name: "Plush blanket", emoji: "🧸",
      useCase: "Convey softness and safety.",
      prompt: "Product resting on a fluffy cream cotton blanket, warm nursery light, cozy soft-focus background, tender comforting mood.",
      negative: COMMON_NEGATIVE, aspect: "4:5" },
    { id: "wood_crib", name: "Wooden crib nook", emoji: "🪵",
      useCase: "Lifestyle nursery scene.",
      prompt: "Product in a bright nursery beside a light wooden crib, soft pastel daylight, airy and clean, gentle out-of-focus nursery decor behind.",
      negative: COMMON_NEGATIVE, aspect: "9:16" },
    { id: "white_clean", name: "Clean white", emoji: "⬜",
      useCase: "Spec shot emphasizing cleanliness.",
      prompt: "Product on a pure white seamless background, even soft shadowless light, crisp clean edges, spotless hygienic look, true color.",
      negative: COMMON_NEGATIVE, aspect: "1:1" },
  ],
  ACCESSORIES: [
    { id: "black_mirror", name: "Black mirror", emoji: "⬛",
      useCase: "Premium hero shot with sharp reflection.",
      prompt: "Product on a glossy black mirror surface, dramatic directional light, crisp reflection beneath, deep black seamless background, high-end tech-accessory aesthetic, sharp specular highlights.",
      negative: COMMON_NEGATIVE, aspect: "1:1" },
    { id: "raw_stone", name: "Raw stone slab", emoji: "🪨",
      useCase: "Rugged, high-end material contrast.",
      prompt: "Product on a raw grey stone slab, moody side light, crisp defined shadow, minimal premium composition, textured natural backdrop.",
      negative: COMMON_NEGATIVE, aspect: "4:5" },
    { id: "desk_setup", name: "Desk setup", emoji: "🖥️",
      useCase: "Show it in a real tech workspace.",
      prompt: "Product on a modern minimalist desk with subtle blurred tech in the background, cool balanced light, clean workspace mood, shallow depth of field.",
      negative: COMMON_NEGATIVE, aspect: "9:16" },
    { id: "white_seamless", name: "White seamless", emoji: "⬜",
      useCase: "Clean marketplace spec shot.",
      prompt: "Product on a pure white seamless studio background, even shadowless lighting, crisp edges, true color, standard e-commerce product photography.",
      negative: COMMON_NEGATIVE, aspect: "1:1" },
  ],
};

export function scenesFor(industry: Industry): StudioScene[] {
  return STUDIO_SCENES[industry];
}

/** Scene info safe to send to the client — the prompt/negative stay server-side. */
export type PublicScene = { id: string; name: string; emoji: string; useCase: string; aspect: string };

export function publicCatalog(): Record<Industry, PublicScene[]> {
  const out = {} as Record<Industry, PublicScene[]>;
  for (const industry of INDUSTRIES) {
    out[industry] = STUDIO_SCENES[industry].map((s) => ({
      id: s.id, name: s.name, emoji: s.emoji, useCase: s.useCase, aspect: s.aspect,
    }));
  }
  return out;
}

export function findScene(industry: Industry, sceneId: string): StudioScene | undefined {
  return STUDIO_SCENES[industry].find((s) => s.id === sceneId);
}
