import { test } from "node:test";
import assert from "node:assert/strict";
import { createClient } from "@supabase/supabase-js";
import {
  AccountDeletionError, accountDeletionRepository, deleteAccount, deleteOrganizationPhotos, deleteDiagnosticTraces,
  type AccountDeletionRepository, type DeletionAccount,
} from "../src/lib/account-deletion.ts";
import { AppleRevocationError, revokeAppleAuthorization } from "../src/lib/apple.ts";
import { signSession, verifyDeletionSession, verifySession } from "../src/lib/session.ts";

function fixture(apple = false, failAt?: string) {
  const calls: string[] = [];
  const account: DeletionAccount = { id: "u1", email: "seller@example.test", appleUserId: apple ? "apple-1" : null, deletedAt: null };
  async function record(name: string, value: string) {
    calls.push(`${name}:${value}`);
    if (name === failAt) throw new AccountDeletionError("Cleanup failed.");
  }
  const repository: AccountDeletionRepository = {
    async account() { return account; },
    async organizations(userId) { await record("organizations", userId); return ["org-1", "org-2"]; },
    async markDeleting(id) { await record("mark", id); account.deletedAt = new Date().toISOString(); },
    async deletePhotos(id) { await record("photos", id); },
    async deleteProducts(id) { await record("products", id); },
    async deleteGenerations(id) { await record("generations", id); },
    async anonymizeWorkspace(id) { await record("workspace", id); },
    async deleteEmailCodes(email) { await record("otp", email); },
    async scrubAccount(id) { await record("scrub", id); account.email = null; account.appleUserId = null; },
  };
  return { calls, account, repository };
}

test("account deletion stops normal access before clearing all owned workspaces and PII", async () => {
  const f = fixture();
  assert.deepEqual(await deleteAccount("u1", {}, f.repository), { appleRevocationRequired: false });
  assert.deepEqual(f.calls, [
    "organizations:u1", "mark:u1", "photos:org-1", "products:org-1", "generations:org-1", "workspace:org-1",
    "photos:org-2", "products:org-2", "generations:org-2", "workspace:org-2", "otp:seller@example.test", "scrub:u1",
  ]);
  assert.ok(f.account.deletedAt);
  assert.equal(f.account.email, null);
});

for (const failure of ["organizations", "mark", "photos", "products", "generations", "workspace", "otp", "scrub"]) {
  test(`a ${failure} failure does not falsely report successful account deletion`, async () => {
    const f = fixture(false, failure);
    await assert.rejects(deleteAccount("u1", {}, f.repository), /Cleanup failed/);
    assert.equal(f.account.email, "seller@example.test", "retain identity until cleanup can be retried");
    if (failure !== "scrub") assert.ok(!f.calls.includes("scrub:u1"));
  });
}

test("Apple reauthentication is requested before any mutation", async () => {
  const f = fixture(true);
  await assert.rejects(deleteAccount("u1", {}, f.repository), (error: unknown) =>
    error instanceof AccountDeletionError && error.status === 428);
  assert.deepEqual(f.calls, []);
});

test("manual Apple revocation is an explicit fallback and still deletes account data", async () => {
  const f = fixture(true);
  const result = await deleteAccount("u1", { skipAppleRevocation: true }, f.repository,
    async () => { assert.fail("must not contact Apple without credentials"); });
  assert.equal(result.appleRevocationRequired, true);
  assert.equal(f.account.appleUserId, null);
});

test("Apple revocation failure is visible and leaves deletion retryable", async () => {
  const f = fixture(true);
  await assert.rejects(deleteAccount("u1", { identityToken: "identity", authorizationCode: "fresh-code" },
    f.repository, async (identity, code, subject) => {
      assert.deepEqual([identity, code, subject], ["identity", "fresh-code", "apple-1"]);
      throw new AppleRevocationError("Apple unavailable.");
    }), (error: unknown) => error instanceof AccountDeletionError && error.status === 428);
  assert.deepEqual(f.calls, []);
});

test("fresh Apple authorization is exchanged then revoked for the verified same subject", async () => {
  const calls: { url: string; body: URLSearchParams }[] = [];
  await revokeAppleAuthorization("identity-1", "code-1", "apple-1", {
    verifyIdentity: async (token) => {
      assert.ok(["identity-1", "exchanged-identity"].includes(token));
      return { appleUserId: "apple-1", email: null };
    },
    clientSecret: async () => "server-only-secret",
    fetch: async (url, init) => {
      calls.push({ url: String(url), body: new URLSearchParams(String(init?.body)) });
      return String(url).endsWith("/token")
        ? Response.json({ id_token: "exchanged-identity", refresh_token: "refresh-1" })
        : new Response(null, { status: 200 });
    },
  });
  assert.equal(calls[0].url, "https://appleid.apple.com/auth/token");
  assert.equal(calls[0].body.get("grant_type"), "authorization_code");
  assert.equal(calls[0].body.get("code"), "code-1");
  assert.equal(calls[1].url, "https://appleid.apple.com/auth/revoke");
  assert.equal(calls[1].body.get("token"), "refresh-1");
  assert.equal(calls[1].body.get("token_type_hint"), "refresh_token");
});

test("a code belonging to another Apple user never reaches the revocation endpoint", async () => {
  const urls: string[] = [];
  await assert.rejects(revokeAppleAuthorization("identity-1", "wrong-code", "apple-1", {
    verifyIdentity: async (token) => ({ appleUserId: token === "identity-1" ? "apple-1" : "apple-other", email: null }),
    clientSecret: async () => "secret",
    fetch: async (url) => {
      urls.push(String(url));
      return Response.json({ id_token: "other-identity", refresh_token: "other-refresh" });
    },
  }), /linked to this Listing Force account/);
  assert.equal(urls.length, 1);
});

test("deleted-account JWTs can only retry deletion, and cannot access normal API routes", async () => {
  const oldSecret = process.env.SESSION_SECRET;
  process.env.SESSION_SECRET = "offline-test-secret-not-used-outside-this-test";
  try {
    const token = await signSession({ userId: "u1", orgId: "org-1" });
    const db = createClient("https://supabase.test", "test-key", { global: { fetch: async (url) => {
      const path = new URL(String(url)).pathname;
      return Response.json(path.endsWith("/users")
        ? { id: "u1", deleted_at: "2026-09-14T00:00:00Z" } : { id: "org-1" });
    } } });
    await assert.rejects(verifySession(`Bearer ${token}`, db), /Account is unavailable/);
    assert.deepEqual(await verifyDeletionSession(`Bearer ${token}`, db), { userId: "u1", orgId: "org-1" });
    await assert.rejects(verifySession(token, db), /Missing bearer/);
  } finally {
    if (oldSecret === undefined) delete process.env.SESSION_SECRET;
    else process.env.SESSION_SECRET = oldSecret;
  }
});

test("storage cleanup visits more than 1000 files and nested multi-angle folders", async () => {
  const removed: string[] = [];
  const listCalls: { prefix: string; offset: number }[] = [];
  const db = createClient("https://supabase.test", "test-key", { global: { fetch: async (url, init) => {
    const path = new URL(String(url)).pathname;
    if (path.includes("/bucket/")) return Response.json({ id: "cutouts", name: "cutouts" });
    const body = JSON.parse(String(init?.body));
    if (path.includes("/object/list/")) {
      listCalls.push(body);
      if (body.prefix === "org-1/nested") return Response.json([{ id: "angle", name: "angle.png" }]);
      if (body.offset === 0) return Response.json([
        { id: null, name: "nested" },
        ...Array.from({ length: 999 }, (_, i) => ({ id: `id-${i}`, name: `photo-${i}.png` })),
      ]);
      return Response.json([{ id: "last", name: "last.png" }]);
    }
    assert.equal(init?.method, "DELETE");
    removed.push(...body.prefixes);
    return Response.json(body.prefixes.map((name: string) => ({ name })));
  } } });
  await deleteOrganizationPhotos(db, "org-1");
  assert.equal(removed.length, 1001);
  assert.ok(removed.includes("org-1/nested/angle.png"));
  assert.ok(removed.includes("org-1/last.png"));
  assert.ok(listCalls.some((call) => call.prefix === "org-1" && call.offset === 1000));
  assert.ok(removed.every((path) => path.startsWith("org-1/")));
});

test("database cleanup errors are propagated instead of reporting a scrubbed account", async () => {
  const db = createClient("https://supabase.test", "test-key", { global: { fetch: async () =>
    Response.json({ message: "database unavailable" }, { status: 503 }) } });
  await assert.rejects(accountDeletionRepository(db).deleteProducts("org-1"), /Could not delete your products/);
});

test("generation trace cleanup batches recorded IDs and rejects provider failures", async () => {
  const configuration = {
    baseURL: () => "https://langfuse.test/",
    publicKey: () => "test-public",
    secretKey: () => "test-secret",
  };
  const batches: string[][] = [];
  await deleteDiagnosticTraces([...Array.from({ length: 51 }, (_, i) => `trace-${i}`), "trace-0"], configuration,
    async (url, init) => {
      assert.equal(String(url), "https://langfuse.test/api/public/traces");
      assert.equal(init?.method, "DELETE");
      batches.push(JSON.parse(String(init?.body)).traceIds);
      return Response.json({ message: "Traces deleted successfully" });
    });
  assert.deepEqual(batches.map((batch) => batch.length), [50, 1]);
  await assert.rejects(deleteDiagnosticTraces(["trace-1"], configuration,
    async () => new Response(null, { status: 429 })), /Could not remove your generation diagnostics/);
});
