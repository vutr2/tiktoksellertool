import { test } from "node:test";
import assert from "node:assert/strict";
import { MARKETPLACE_IDS, allRules, pendingVerifications, rulesFor } from "../../src/lib/rules/registry.ts";

test("all four v1 marketplaces are configured", () => {
  assert.deepEqual([...MARKETPLACE_IDS].sort(), ["amazon", "ebay", "etsy", "tiktok_shop"]);
});

test("each config's id matches the key it is registered under", () => {
  for (const id of MARKETPLACE_IDS) {
    assert.equal(rulesFor(id).id, id);
  }
});

test("tier gating matches the design's marketplace picker", () => {
  // Screen 3: TikTok Shop is "Included", the other three are badged "Pro".
  assert.equal(rulesFor("tiktok_shop").tier, "included");
  for (const id of ["amazon", "ebay", "etsy"] as const) {
    assert.equal(rulesFor(id).tier, "pro", `${id} should be Pro`);
  }
});

test("every config carries a version so the device cache can be invalidated", () => {
  for (const rules of allRules()) {
    assert.ok(rules.version.length > 0, `${rules.id} has no version`);
    assert.ok(rules.summary.length > 0, `${rules.id} has no summary`);
  }
});

test("no limit is presented as verified — every marketplace has open TODOs", () => {
  // SPEC §7: "Do not invent limits from memory." Nothing here has been checked
  // against a live marketplace spec, and the config says so.
  const pending = pendingVerifications();
  for (const id of MARKETPLACE_IDS) {
    assert.ok(
      pending.some((p) => p.marketplace === id),
      `${id} claims to be verified but nothing has been checked`,
    );
  }
});

test("pending verifications report a path and a source hint", () => {
  for (const item of pendingVerifications()) {
    assert.ok(item.path.length > 0);
    assert.ok(item.source && item.source.length > 0, `${item.marketplace}.${item.path} has no source hint`);
  }
});
