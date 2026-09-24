import { test } from "node:test";
import assert from "node:assert/strict";
import { createClient } from "@supabase/supabase-js";
import { deleteProduct, ownsProductPhoto } from "../src/lib/product-management.ts";

const id = "36ba14f2-3bab-4b13-bb05-c7cb3d6e31d2";
const org = "customer-one";
const prefix = `${org}/${id}`;

// Deletion compliance: one customer's request must never remove another
// customer's photos, or report success while their own photos remain.
test("an inaccessible product is an idempotent no-op with no storage access", async () => {
  let calls = 0;
  const db = createClient("https://supabase.test", "test-key", { global: { fetch: async (input, init) => {
    calls++;
    const url = new URL(String(input));
    assert.equal(init?.method, "GET");
    assert.equal(url.pathname, "/rest/v1/products");
    assert.equal(url.searchParams.get("org_id"), `eq.${org}`);
    assert.equal(url.searchParams.get("id"), `eq.${id}`);
    return Response.json([]);
  } } });
  await deleteProduct(org, id, db);
  assert.equal(calls, 1);
});

test("a live credit reservation prevents product deletion", async () => {
  const db = createClient("https://supabase.test", "test-key", { global: { fetch: async (input, init) => {
    const url = new URL(String(input));
    assert.equal(init?.method, "GET");
    assert.equal(url.searchParams.get("org_id"), `eq.${org}`);
    if (url.pathname.endsWith("/products")) return Response.json([{ id, attributes: { captureStatus: "ready" } }]);
    assert.equal(url.pathname, "/rest/v1/generation_requests");
    assert.equal(url.searchParams.get("product_id"), `eq.${id}`);
    assert.equal(url.searchParams.get("status"), "eq.running");
    assert.ok(url.searchParams.has("lease_expires_at"));
    return Response.json([{ id: "paid-generation" }]);
  } } });
  await assert.rejects(deleteProduct(org, id, db), /generating a listing/);
});

test("deletion cleans every page and nested photo before removing the scoped record", async () => {
  const removed: string[] = [];
  let marked = false;
  let deleted = false;
  const db = createClient("https://supabase.test", "test-key", { global: { fetch: async (input, init) => {
    const url = new URL(String(input));
    if (url.pathname.startsWith("/rest/v1/")) {
      assert.equal(url.searchParams.get("org_id"), `eq.${org}`);
      if (url.pathname.endsWith("/generation_requests")) return Response.json([]);
      assert.equal(url.searchParams.get("id"), `eq.${id}`);
      if (init?.method === "GET") return Response.json([{ id, cutout_url: `${prefix}.png`, attributes: { captureStatus: "ready", hidden: true } }]);
      if (init?.method === "PATCH") {
        assert.equal(JSON.parse(String(init.body)).attributes.captureStatus, "deleting");
        assert.equal(JSON.parse(String(init.body)).attributes.hidden, true);
        assert.ok(url.searchParams.has("attributes"));
        marked = true;
        return Response.json([{ id }]);
      }
      assert.equal(init?.method, "DELETE");
      assert.equal(removed.length, 1003);
      deleted = true;
      return new Response(null, { status: 204 });
    }
    assert.ok(marked);
    if (url.pathname.includes("/bucket/")) return Response.json({ id: "cutouts" });
    const body = JSON.parse(String(init?.body));
    if (url.pathname.includes("/object/list/")) {
      if (body.prefix === `${prefix}/studio`) return Response.json([{ id: "studio-image", name: "result.png" }]);
      assert.equal(body.prefix, prefix);
      if (body.offset === 0) return Response.json([
        { id: null, name: "studio" },
        ...Array.from({ length: 999 }, (_, i) => ({ id: `photo-${i}`, name: `${i}.png` })),
      ]);
      assert.equal(body.offset, 1000);
      return Response.json([{ id: "last-a", name: "last-a.png" }, { id: "last-b", name: "last-b.png" }]);
    }
    assert.equal(init?.method, "DELETE");
    assert.ok(body.prefixes.length <= 100);
    removed.push(...body.prefixes);
    return Response.json([]);
  } } });
  await deleteProduct(org, id, db);
  assert.ok(deleted);
  assert.equal(new Set(removed).size, removed.length);
  assert.ok(removed.every(path => ownsProductPhoto(org, id, path)));
  assert.ok(removed.includes(`${prefix}/studio/result.png`));
  assert.ok(removed.includes(`${prefix}.png`));
});

test("storage failure retains the marked product for a safe retry", async () => {
  let removed = false;
  const db = createClient("https://supabase.test", "test-key", { global: { fetch: async (input, init) => {
    const url = new URL(String(input));
    if (url.pathname.endsWith("/products")) {
      assert.equal(init?.method, "GET", "the retry must not delete the database record on failure");
      return Response.json([{ id, cutout_url: `${prefix}.png`, attributes: { captureStatus: "deleting" } }]);
    }
    if (url.pathname.endsWith("/generation_requests")) return Response.json([]);
    if (url.pathname.includes("/bucket/")) return Response.json({ id: "cutouts" });
    if (url.pathname.includes("/object/list/")) return Response.json([]);
    removed = true;
    return Response.json({ message: "Unavailable", statusCode: "503" }, { status: 503 });
  } } });
  await assert.rejects(deleteProduct(org, id, db), /photos could not be deleted/);
  assert.ok(removed);
});

test("foreign paths and traversal never qualify for product photo deletion", () => {
  for (const path of [`other/${id}.png`, `${org}/other.png`, `${prefix}/../other.png`, `${prefix}//image.png`, `${prefix}/./image.png`, `${prefix}-other/photo.png`]) {
    assert.equal(ownsProductPhoto(org, id, path), false, path);
  }
});
