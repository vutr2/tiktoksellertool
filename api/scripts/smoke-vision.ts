// One real Claude call to prove the provider path works end to end.
// Run: node --env-file=.env scripts/smoke-vision.ts
import { deflateSync } from "node:zlib";
import { AnthropicVisionProvider } from "../src/lib/ai/anthropic.ts";

// A plain drawn scene, enough to exercise auth, image upload, parsing, usage
// and pricing. Not a judgement of segmentation quality.
function png(): Uint8Array {
  const table: number[] = [];
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; table[n] = c >>> 0; }
  const chunk = (type: string, data: Buffer) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
    let crc = 0xffffffff; for (const b of body) crc = table[(crc ^ b) & 0xff] ^ (crc >>> 8);
    const cb = Buffer.alloc(4); cb.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([len, body, cb]);
  };
  const W = 128, H = 128;
  const raw = Buffer.alloc((W * 4 + 1) * H);
  for (let y = 0; y < H; y++) {
    const row = y * (W * 4 + 1);
    for (let x = 0; x < W; x++) {
      const i = row + 1 + x * 4;
      const inCircle = (x - 64) ** 2 + (y - 64) ** 2 < 45 ** 2;
      raw[i] = inCircle ? 40 : 250; raw[i + 1] = inCircle ? 90 : 250;
      raw[i + 2] = inCircle ? 200 : 250; raw[i + 3] = 255;
    }
  }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

const result = await new AnthropicVisionProvider().readProduct({ bytes: png(), mediaType: "image/png" });
console.log("--- facts ---");
console.log("  name    :", result.value.suggestedName);
console.log("  category:", result.value.suggestedCategory);
console.log("  features:", result.value.keyFeatures.join(", ") || "(none)");
console.log("--- usage (what a generations row records) ---");
console.log("  model   :", result.usage.model);
console.log("  tokens  :", result.usage.inputTokens, "in /", result.usage.outputTokens, "out");
console.log("  cost    :", result.usage.costUSD === null ? "null (rate unknown)" : "$" + result.usage.costUSD.toFixed(6));
console.log("  latency :", result.usage.latencyMs + "ms");
console.log("  traceId :", result.usage.traceId ?? "null (Langfuse not configured)");
