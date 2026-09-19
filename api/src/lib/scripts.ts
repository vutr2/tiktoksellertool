// Structured 30-second video scripts (hook + timed beats) that drive the app's
// 9:16 preview player. Ported (in English) from tiktok_tools.
//
// The model miscounts time, so durations are audited here — never trusted as
// returned. Pure functions only (no SDK), so they stay unit-testable.

/** Strips a code fence the model may have added despite being asked not to. */
function stripFence(text: string): string {
  const fenced = text.match(/^\s*```(?:json)?\s*\n([\s\S]*?)\n?\s*```\s*$/);
  return (fenced ? fenced[1] : text).trim();
}

export type VideoScriptBeat = {
  /** DURATION of the beat in seconds, not a start mark. */
  seconds: number;
  voiceover: string;
  shot: string;
  onScreenText: string;
};

export type VideoScript = {
  id: string;
  hook: VideoScriptBeat;
  scenes: VideoScriptBeat[];
};

export const TARGET_SECONDS = 30;
export const HOOK_SECONDS = 3;
const MIN_BEAT_SECONDS = 0.5;

export function scriptsPrompt(input: {
  name: string;
  category: string;
  keyFeatures: string[];
  count: number;
  voice?: string;
}): string {
  const { name, category, keyFeatures, count, voice } = input;
  return `Write ${count} short-form vertical video ad scripts for this product.

Product: ${name}
Category: ${category || "unspecified"}
Key features: ${keyFeatures.join(", ") || "none given"}
${voice ? `Selling voice: ${voice}\n` : ""}
Each script is about ${TARGET_SECONDS} seconds and has:
- a "hook" beat of about ${HOOK_SECONDS} seconds that earns the first three seconds,
- 3 to 5 following "scenes".

Every beat has:
- "seconds": how long the beat lasts (a number),
- "voiceover": what the creator says,
- "shot": a concrete camera/shot suggestion,
- "onScreenText": the short caption shown on screen for that beat.

Claim nothing that is not in the product details above. Keep captions punchy.

Reply with JSON only, no prose and no code fences:
[
  {
    "hook": { "seconds": number, "voiceover": string, "shot": string, "onScreenText": string },
    "scenes": [ { "seconds": number, "voiceover": string, "shot": string, "onScreenText": string } ]
  }
]`;
}

function beat(raw: unknown): VideoScriptBeat | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const voiceover = typeof o.voiceover === "string" ? o.voiceover.trim() : "";
  const shot = typeof o.shot === "string" ? o.shot.trim() : "";
  const onScreenText = typeof o.onScreenText === "string" ? o.onScreenText.trim() : "";
  if (!voiceover && !onScreenText) return null;
  const seconds = typeof o.seconds === "number" && Number.isFinite(o.seconds) && o.seconds > 0
    ? Math.max(MIN_BEAT_SECONDS, o.seconds)
    : 3;
  return { seconds, voiceover, shot, onScreenText: onScreenText || voiceover };
}

/**
 * Parse and audit the model's output. Fixes durations rather than trusting them,
 * and drops malformed scripts instead of surfacing a broken one.
 */
export function parseVideoScripts(text: string, makeId: (index: number) => string): VideoScript[] {
  let raw: unknown;
  try { raw = JSON.parse(stripFence(text)); } catch { return []; }
  if (!Array.isArray(raw)) return [];

  const scripts: VideoScript[] = [];
  raw.forEach((entry, index) => {
    if (!entry || typeof entry !== "object") return;
    const o = entry as Record<string, unknown>;
    const hook = beat(o.hook);
    const scenes = Array.isArray(o.scenes)
      ? o.scenes.map(beat).filter((b): b is VideoScriptBeat => b !== null)
      : [];
    if (!hook || scenes.length === 0) return;
    scripts.push({ id: makeId(index), hook, scenes });
  });
  return scripts;
}
