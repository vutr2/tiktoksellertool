// Renders every RuleCopy / ConvertCopy builder into a real sentence.
//
// The builders are functions, so a reviewer handed `titleTooLong` learns
// nothing. Given example figures they read the sentence a seller reads.

import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join } from "node:path";

// An ESM relative import resolves against this file's own URL, not the working
// directory, so the module is addressed from the repository root instead.
const repo = dirname(dirname(fileURLToPath(import.meta.url)));
const { convertCopy, ruleCopy } =
  await import(pathToFileURL(join(repo, "api/src/lib/rules/messages.ts")).href);

// One realistic argument list per builder. A builder added without an entry
// here is reported rather than skipped silently, so the review cannot quietly
// lose a message.
const EXAMPLES = {
  imageSlot: ["main"], contentLabel: ["text"],
  aspectRatio: ["Amazon", "1:1", "ảnh chính"], imageSize: [2000, 1000],
  minLongestEdge: ["Amazon", "ảnh chính", 1600], maxLongestEdge: ["Amazon", "ảnh chính", 5000],
  backgroundUnknown: ["Amazon", "ảnh chính"], backgroundUnmeasured: [],
  backgroundNotWhite: ["Amazon", "ảnh chính"], backgroundColour: [248, 247, 240],
  fillUnknown: [], fillExpectation: ["Amazon", "85%"],
  fillTooSmall: ["Amazon", "85%", "ảnh chính"], fillTooLarge: ["Amazon", "95%", "ảnh chính"],
  fillActual: ["62%"], contentUnchecked: ["Amazon", "ảnh chính"],
  contentForbids: ["Amazon", "logo, watermark"], contentNotAllowed: ["Amazon", "logo", "ảnh chính"],
  titleTooLong: ["Amazon", 200], titleLengthOver: [215, 15], titleTooShort: ["Amazon", 15],
  titleLength: [12], titleAllCaps: ["Amazon"], titlePromo: ["Amazon"],
  titlePromoFound: ["free shipping"], titlePromoUnchecked: ["Amazon"],
  titlePromoUncheckedDetail: [],
  descriptionNeedsBullets: ["Amazon"], descriptionIsOneBlock: [],
  descriptionTooManyBullets: ["Amazon", 5], descriptionBulletCount: [7],
  descriptionBulletTooLong: ["Amazon", 200], descriptionBulletLength: [3, 240],
  descriptionTooLong: ["Amazon", 2000], descriptionLength: [2400],
  personStillVisible: [], personStillVisibleDetail: ["Amazon", "ảnh chính"],
  croppedToRatio: ["1:1"], croppedToRatioDetail: ["2000×1000", 1000, 1000, "Amazon"],
  resized: [1600, 1600], resizedDetail: ["6000×6000", 5000],
  croppedToFill: ["85%"], croppedToFillDetail: ["62%", "Amazon", "85%"],
  borderCropped: [], borderCroppedDetail: ["Amazon"],
  overlayTextRemoved: [], overlayTextRemovedDetail: ["ảnh chính", "Amazon"],
  backgroundWhitened: [], backgroundWhitenedDetail: ["255/255/255", "Amazon"],
};

const rows = [];
const missing = [];
for (const [group, en, vi] of [
  ["rules", ruleCopy("en"), ruleCopy("vi")],
  ["convert", convertCopy("en"), convertCopy("vi")],
]) {
  for (const key of Object.keys(vi)) {
    const args = EXAMPLES[key];
    if (!args) { missing.push(`${group}.${key}`); continue; }
    rows.push({ group, key, en: en[key](...args), vi: vi[key](...args) });
  }
}

if (missing.length > 0) {
  console.error(`No example arguments for: ${missing.join(", ")}`);
  console.error("Add them to EXAMPLES so the wording review does not lose these messages.");
  process.exit(1);
}
process.stdout.write(JSON.stringify(rows));
