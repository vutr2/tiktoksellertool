// Which language each stored asset was written in.
//
// A product accumulates assets across generations: `complete_generation`
// inserts new rows and keeps the old ones. So a seller can generate Vietnamese
// copy, switch the app to English, generate again, and end up with a product
// holding both. Taking the language from the newest completed request and
// applying it to every row tells the rules engine that the older Vietnamese
// copy is English — and its English-only content checks then report copy they
// never read as clean.
//
// No new column is needed: `complete_generation` writes each new asset row's id
// back into the result it stores, so the mapping is already recorded.

/** The stored result as it comes out of the jsonb column: only the two fields
 *  this needs are described, and the rest is whatever was written. */
export interface StoredGenerationResult {
  language?: unknown;
  assets?: { id?: unknown }[] | unknown;
  failures?: unknown;
}

/**
 * Asset id → the language of the generation that produced it.
 *
 * Rows produced before results recorded a language are English: that is what
 * the app could write at the time, a fact about the text rather than a guess.
 * Rows in no result at all are simply absent — unknown origin is not English,
 * and the caller decides what to do about it.
 *
 * History is walked oldest-first so that if an id somehow appears twice, the
 * most recent generation wins, matching what the seller last paid for.
 */
export function assetLanguages(history: { result: StoredGenerationResult | null }[]): Map<string, string> {
  const languages = new Map<string, string>();
  for (const row of [...history].reverse()) {
    const result = row?.result;
    if (!result || !Array.isArray(result.assets)) continue;
    const language = typeof result.language === "string" ? result.language : "en";
    for (const asset of result.assets as { id?: unknown }[]) {
      if (asset && typeof asset.id === "string") languages.set(asset.id, language);
    }
  }
  return languages;
}
