// Seller-facing messages in the language the app asked for.
//
// The English message is the key. That keeps SPEC §10 intact — the source
// still reads as plain English at every throw site — and means a message with
// no translation yet degrades to English rather than to a code or a blank.
//
// Only text a seller can read is translated. Configuration failures and
// internal invariants stay English on purpose: they are for whoever is holding
// the pager, not for the person trying to list a coffee dripper.

import type { OutputLanguage } from "../ai/types.ts";
import { VI } from "./vi.ts";

/** Messages that carry numbers, matched by shape rather than by exact text. */
const PATTERNS: { test: RegExp; vi: (match: RegExpMatchArray) => string }[] = [
  {
    test: /^This needs (\d+) credits and you have (\d+)\.$/,
    vi: (m) => `Việc này cần ${m[1]} credit nhưng bạn chỉ còn ${m[2]}.`,
  },
  {
    test: /^Claude returned an error \((.+)\)\.$/,
    vi: (m) => `Claude trả về lỗi (${m[1]}).`,
  },
];

export function localize(message: string, language: OutputLanguage): string {
  if (language === "en") return message;
  const exact = VI[message];
  if (exact) return exact;
  for (const { test, vi } of PATTERNS) {
    const match = message.match(test);
    if (match) return vi(match);
  }
  return message;
}

const SUPPORTED: readonly string[] = ["en", "vi"];

/**
 * Picks a language from an `Accept-Language` header.
 *
 * Deliberately simple: this chooses which of two message tables to read, not
 * which of a hundred regional variants to serve. Quality values are honoured
 * so a phone sending "vi-VN;q=0.9, en;q=0.8" is understood, and anything
 * unrecognised falls back to English rather than failing the request — an
 * error the seller cannot read is still better than no answer at all.
 */
export function languageFromHeader(header: string | null | undefined): OutputLanguage {
  if (!header) return "en";
  const ranked = header
    .split(",")
    .map((part) => {
      const [tag, ...params] = part.trim().split(";");
      const q = params.map((p) => p.trim()).find((p) => p.startsWith("q="));
      const quality = q ? Number.parseFloat(q.slice(2)) : 1;
      return { tag: tag.trim().toLowerCase(), quality: Number.isFinite(quality) ? quality : 0 };
    })
    .filter((entry) => entry.tag && entry.quality > 0)
    .sort((a, b) => b.quality - a.quality);

  for (const { tag } of ranked) {
    const base = tag.split("-")[0];
    if (SUPPORTED.includes(base)) return base as OutputLanguage;
  }
  return "en";
}
