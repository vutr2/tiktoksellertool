import { test } from "node:test";
import assert from "node:assert/strict";
import { ImageTaskCache, SharedStudioWork, TaskCacheFullError } from "../../src/lib/ai/image-task-cache.ts";

test("concurrent retries reuse one paid task and keep it after a polling failure", async () => {
  const cache = new ImageTaskCache();
  let submissions = 0;
  const submit = async () => ({ taskId: `paid-${++submissions}`, model: "stub" });
  const first = cache.getOrSubmit("org/product/scene/0", "same-input", submit);
  const retry = cache.getOrSubmit("org/product/scene/0", "same-input", submit);
  assert.deepEqual(await first.submission, await retry.submission);
  const afterFailedPoll = cache.getOrSubmit("org/product/scene/0", "same-input", submit);
  assert.equal((await afterFailedPoll.submission).taskId, "paid-1");
  assert.equal(submissions, 1);
});

test("a lost submission response stays uncertain and is not submitted again", async () => {
  const cache = new ImageTaskCache();
  let submissions = 0;
  const submit = async (): Promise<{ taskId: string; model: string }> => {
    submissions++;
    throw new Error("Response lost after the provider accepted payment");
  };
  await assert.rejects(cache.getOrSubmit("variation", "input", submit).submission);
  await assert.rejects(cache.getOrSubmit("variation", "input", submit).submission);
  assert.equal(submissions, 1);
});

test("different owners/variations cannot reuse another task", async () => {
  const cache = new ImageTaskCache();
  let submissions = 0;
  const submit = async () => ({ taskId: `paid-${++submissions}`, model: "stub" });
  for (const key of ["owner1/product/scene/0", "owner2/product/scene/0", "owner1/product/scene/1"]) {
    await cache.getOrSubmit(key, "same-input", submit).submission;
  }
  assert.equal(submissions, 3);
});

test("changed input cannot silently replace a paid pending task", async () => {
  const cache = new ImageTaskCache();
  let submissions = 0;
  const submit = async () => ({ taskId: `paid-${++submissions}`, model: "stub" });
  await cache.getOrSubmit("variation", "original", submit).submission;
  assert.throws(() => cache.getOrSubmit("variation", "changed", submit), /different task/);
  assert.equal(submissions, 1);
});

test("capacity pressure does not evict unresolved paid work", async () => {
  const cache = new ImageTaskCache(1);
  let submissions = 0;
  const submit = async () => ({ taskId: `paid-${++submissions}`, model: "stub" });
  await cache.getOrSubmit("pending", "input", submit).submission;
  assert.throws(() => cache.getOrSubmit("new", "input", submit), TaskCacheFullError);
  assert.equal((await cache.getOrSubmit("pending", "input", submit).submission).taskId, "paid-1");
  assert.equal(submissions, 1);
  cache.forget("pending"); // Only after durable save, or a definite rejection.
  await cache.getOrSubmit("new", "input", submit).submission;
  assert.equal(submissions, 2);
});

test("concurrent requests join saving and charging, not only image creation", async () => {
  const work = new SharedStudioWork<{ path: string; charged: number }>();
  let charges = 0;
  let saved: string | undefined;
  const operation = async () => {
    if (saved) return { path: saved, charged: 0 };
    // Represents async generation/storage/ledger calls.
    await new Promise(resolve => setImmediate(resolve));
    saved = "saved-output";
    charges++;
    return { path: saved, charged: 5 };
  };
  const results = await Promise.all(Array.from({ length: 10 }, () => work.run("owned-variation", operation)));
  assert.equal(charges, 1);
  assert.ok(results.every(result => result.path === "saved-output"));
  assert.equal((await work.run("owned-variation", operation)).charged, 0);
  assert.equal(charges, 1);
});

test("a failed shared operation releases its lock so the same task can be recovered", async () => {
  const work = new SharedStudioWork<number>();
  await assert.rejects(work.run("variation", async () => { throw new Error("Temporary download failure"); }));
  assert.equal(await work.run("variation", async () => 5), 5);
});
