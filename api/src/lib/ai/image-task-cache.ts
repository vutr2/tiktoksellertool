// This cache only survives within one Vercel process. Persisted Studio assets
// are the durable result cache; durable *pending* jobs need a database change.

export class TaskCacheFullError extends Error {}

export type CachedImageTask = {
  inputHash: string;
  submission: Promise<{ taskId: string; model: string }>;
};

export class ImageTaskCache {
  private readonly tasks = new Map<string, CachedImageTask>();
  private readonly capacity: number;

  constructor(capacity = 128) { this.capacity = capacity; }

  getOrSubmit(key: string, inputHash: string,
    submit: () => Promise<{ taskId: string; model: string }>): CachedImageTask {
    const existing = this.tasks.get(key);
    if (existing) {
      if (existing.inputHash !== inputHash) throw new Error("This Studio variation already has a different task in progress.");
      return existing;
    }
    // Never evict an unresolved submission to make room: resubmitting it could
    // incur a second provider charge. Refuse new work when the cache is full.
    if (this.tasks.size >= this.capacity) throw new TaskCacheFullError("Studio is busy. Try again later.");
    const task = { inputHash, submission: Promise.resolve().then(submit) };
    this.tasks.set(key, task);
    return task;
  }

  forget(key: string, expected?: CachedImageTask) {
    if (!expected || this.tasks.get(key) === expected) this.tasks.delete(key);
  }
}

/** Join the whole save/charge operation, not just its billable provider call. */
export class SharedStudioWork<T> {
  private readonly running = new Map<string, Promise<T>>();

  async run(key: string, operation: () => Promise<T>): Promise<T> {
    const existing = this.running.get(key);
    if (existing) return existing;
    const work = Promise.resolve().then(operation);
    this.running.set(key, work);
    try {
      return await work;
    } finally {
      if (this.running.get(key) === work) this.running.delete(key);
    }
  }
}
