import { test } from "node:test";
import assert from "node:assert/strict";
import {
  MAX_CUTOUT_BYTES,
  cutoutPath,
  validateCreateProduct,
} from "../src/lib/products.ts";

/** Minimal valid PNG: signature plus a byte of payload. */
const pngBytes = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  Buffer.from([0x00]),
]);
const pngBase64 = pngBytes.toString("base64");

const ok = (input: Parameters<typeof validateCreateProduct>[0]) => {
  const result = validateCreateProduct(input);
  assert.ok(result.ok, `expected valid, got: ${result.ok ? "" : result.error}`);
  return result.value;
};
const fails = (input: Parameters<typeof validateCreateProduct>[0]) => {
  const result = validateCreateProduct(input);
  assert.ok(!result.ok, "expected invalid");
  return result.error;
};

test("a name is required and is trimmed", () => {
  assert.equal(ok({ name: "  Ceramic pour-over dripper  " }).name, "Ceramic pour-over dripper");
  assert.match(fails({}), /name/i);
  assert.match(fails({ name: "   " }), /name/i);
});

test("an over-long name is rejected with the limit named", () => {
  assert.match(fails({ name: "x".repeat(201) }), /200 characters/);
});

test("category is optional and blank means absent, not an empty string", () => {
  assert.equal(ok({ name: "Dripper" }).category, null);
  assert.equal(ok({ name: "Dripper", category: "   " }).category, null);
  assert.equal(ok({ name: "Dripper", category: " Home & Kitchen › Coffee " }).category,
    "Home & Kitchen › Coffee");
});

test("key features are cleaned rather than trusted", () => {
  const value = ok({
    name: "Dripper",
    keyFeatures: ["  Ceramic  ", "", "   ", "Pour-over", 42, null],
  });
  assert.deepEqual(value.keyFeatures, ["Ceramic", "Pour-over"]);
});

test("too many or too long key features are rejected", () => {
  assert.match(fails({ name: "D", keyFeatures: Array(11).fill("a") }), /10 key features/);
  assert.match(fails({ name: "D", keyFeatures: ["x".repeat(301)] }), /300 characters/);
  assert.match(fails({ name: "D", keyFeatures: "not a list" }), /list/i);
});

test("the cutout is optional — a product can exist before its photo does", () => {
  assert.equal(ok({ name: "Dripper" }).cutout, null);
  assert.equal(ok({ name: "Dripper", cutoutPngBase64: null }).cutout, null);
});

test("a PNG cutout is accepted, with or without a data: prefix", () => {
  assert.ok(ok({ name: "D", cutoutPngBase64: pngBase64 }).cutout?.equals(pngBytes));
  assert.ok(
    ok({ name: "D", cutoutPngBase64: `data:image/png;base64,${pngBase64}` }).cutout?.equals(pngBytes),
  );
});

test("anything that is not a PNG is refused — alpha is what the pipeline needs", () => {
  // A JPEG would lose transparency, so compositing would paste a white box
  // onto the generated background (SPEC §4.1/§8).
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00]).toString("base64");
  assert.match(fails({ name: "D", cutoutPngBase64: jpeg }), /PNG with transparency/);
  assert.match(fails({ name: "D", cutoutPngBase64: "not base64 at all!!" }), /PNG with transparency/);
  assert.match(fails({ name: "D", cutoutPngBase64: "" }), /empty/i);
  assert.match(fails({ name: "D", cutoutPngBase64: 123 }), /base64/i);
});

test("an oversized cutout is refused before it reaches storage", () => {
  const huge = Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    Buffer.alloc(MAX_CUTOUT_BYTES + 1),
  ]).toString("base64");
  assert.match(fails({ name: "D", cutoutPngBase64: huge }), /too large/i);
});

test("cutout paths are scoped by org so one seller cannot reach another's", () => {
  const path = cutoutPath("org-1", "prod-9");
  assert.equal(path, "org-1/prod-9.png");
  assert.ok(path.startsWith("org-1/"), "org scoping is the access boundary");
});

test("validation messages tell the seller what to do, not what the code expects", () => {
  for (const message of [
    fails({}),
    fails({ name: "x".repeat(201) }),
    fails({ name: "D", cutoutPngBase64: "zzz" }),
  ]) {
    assert.ok(message.length > 10, message);
    assert.match(message, /[.!]$/, `not a sentence: ${message}`);
    assert.ok(!message.includes("undefined"), message);
  }
});
