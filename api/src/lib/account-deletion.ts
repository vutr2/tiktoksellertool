import type { SupabaseClient } from "@supabase/supabase-js";
import { supabaseAdmin } from "./supabase.ts";
import { AppleRevocationError, revokeAppleAuthorization } from "./apple.ts";
import { langfuse } from "./env.ts";

export interface DeleteAccountInput {
  identityToken?: string;
  authorizationCode?: string;
  skipAppleRevocation?: boolean;
}

export interface DeletionAccount {
  id: string;
  email: string | null;
  appleUserId: string | null;
  deletedAt: string | null;
}

/** This boundary lets privacy compliance checks run without live data. */
export interface AccountDeletionRepository {
  account(userId: string): Promise<DeletionAccount | null>;
  organizations(userId: string): Promise<string[]>;
  markDeleting(userId: string): Promise<void>;
  deletePhotos(orgId: string): Promise<void>;
  deleteProducts(orgId: string): Promise<void>;
  deleteGenerations(orgId: string): Promise<void>;
  anonymizeWorkspace(orgId: string): Promise<void>;
  deleteEmailCodes(email: string): Promise<void>;
  scrubAccount(userId: string): Promise<void>;
}

export class AccountDeletionError extends Error {
  readonly status: number;
  constructor(message: string, status = 500) {
    super(message);
    this.status = status;
  }
}

/**
 * Deletion is retryable. Normal API access stops before cleanup; the deletion
 * route alone accepts the old session until cleanup succeeds. No success is
 * returned while any checked cleanup step has failed.
 *
 * Apple permits manual revocation when credentials cannot be obtained (TN3194).
 * That fallback must be explicitly chosen by the person deleting the account.
 * Ledger/subscription audit records remain, with account/workspace scrubbed.
 * Deleting an account does not cancel an App Store subscription.
 */
export async function deleteAccount(
  userId: string,
  input: DeleteAccountInput,
  repository: AccountDeletionRepository = accountDeletionRepository(),
  revokeApple = revokeAppleAuthorization,
): Promise<{ appleRevocationRequired: boolean }> {
  const account = await repository.account(userId);
  if (!account) throw new AccountDeletionError("Account not found.", 401);

  // Preserve the manual instructions if the first successful response was lost
  // and the app retries after the Apple subject has already been scrubbed.
  let appleRevocationRequired = input.skipAppleRevocation === true;
  if (account.appleUserId) {
    if (input.skipAppleRevocation === true) {
      appleRevocationRequired = true;
    } else {
      if (!input.identityToken || !input.authorizationCode) {
        throw new AccountDeletionError("Sign in with Apple to confirm account deletion.", 428);
      }
      try {
        await revokeApple(input.identityToken, input.authorizationCode, account.appleUserId);
      } catch (error) {
        throw new AccountDeletionError(
          error instanceof AppleRevocationError ? error.message
            : "Apple access could not be revoked. Try again or choose manual revocation.",
          428,
        );
      }
    }
  }

  // Fetch before tombstoning so a lookup outage does not interrupt an active
  // account. A failed cleanup keeps PII long enough to retry the remaining
  // work; the final step removes it.
  const orgIds = await repository.organizations(userId);
  await repository.markDeleting(userId);
  for (const orgId of orgIds) {
    await repository.deletePhotos(orgId);
    await repository.deleteProducts(orgId);
    await repository.deleteGenerations(orgId);
    await repository.anonymizeWorkspace(orgId);
  }
  if (account.email) await repository.deleteEmailCodes(account.email);
  await repository.scrubAccount(userId);
  return { appleRevocationRequired };
}

function checked(error: { message: string } | null, message: string): void {
  if (error) throw new AccountDeletionError(message);
}

/** Lists every page, including multi-angle subfolders, before removing batches. */
export async function deleteOrganizationPhotos(db: SupabaseClient, orgId: string): Promise<void> {
  const bucket = db.storage.from("cutouts");
  const { error: bucketError } = await db.storage.getBucket("cutouts");
  if (bucketError) {
    // Accounts with no uploads may predate creation of the private bucket.
    if (bucketError.message === "Bucket not found" ||
        ("status" in bucketError && bucketError.status === 404)) return;
    throw new AccountDeletionError("Could not check your photos. Try again.");
  }
  const paths: string[] = [];
  async function collect(prefix: string): Promise<void> {
    let offset = 0;
    while (true) {
      const { data, error } = await bucket.list(prefix, {
        limit: 1000, offset, sortBy: { column: "name", order: "asc" },
      });
      checked(error, "Could not list your photos. Try again.");
      if (!data) throw new AccountDeletionError("Could not list your photos. Try again.");
      for (const item of data) {
        if (!item.name || item.name === "." || item.name === ".." || item.name.includes("/")) {
          throw new AccountDeletionError("Could not read a stored photo path. Contact support.");
        }
        const path = `${prefix}/${item.name}`;
        if (item.id === null) await collect(path);
        else paths.push(path);
      }
      if (data.length < 1000) break;
      offset += data.length;
    }
  }
  await collect(orgId);
  for (let offset = 0; offset < paths.length; offset += 100) {
    const { error } = await bucket.remove(paths.slice(offset, offset + 100));
    checked(error, "Could not delete your photos. Try again.");
  }
}

/** Langfuse schedules trace erasure; provider storage may take time to converge. */
export async function deleteDiagnosticTraces(
  traceIds: string[],
  configuration = {
    baseURL: langfuse.baseURL,
    publicKey: langfuse.publicKey,
    secretKey: langfuse.secretKey,
  },
  transport: typeof fetch = globalThis.fetch,
): Promise<void> {
  const uniqueIds = [...new Set(traceIds)];
  if (uniqueIds.length === 0) return;
  try {
    const baseURL = configuration.baseURL().replace(/\/+$/, "");
    const authorization = `Basic ${Buffer.from(`${configuration.publicKey()}:${configuration.secretKey()}`).toString("base64")}`;
    // Stay within Langfuse's recommended 30–50 IDs per deletion request.
    for (let start = 0; start < uniqueIds.length; start += 50) {
      const response = await transport(`${baseURL}/api/public/traces`, {
        method: "DELETE",
        headers: { Authorization: authorization, "Content-Type": "application/json" },
        body: JSON.stringify({ traceIds: uniqueIds.slice(start, start + 50) }),
        signal: AbortSignal.timeout(15_000),
      });
      if (!response.ok) throw new Error("Trace deletion was not accepted.");
    }
  } catch {
    throw new AccountDeletionError("Could not remove your generation diagnostics. Retry deletion or contact support.");
  }
}

export function accountDeletionRepository(db: SupabaseClient = supabaseAdmin()): AccountDeletionRepository {
  return {
    async account(userId) {
      const { data, error } = await db.from("users")
        .select("id, email, apple_user_id, deleted_at").eq("id", userId).maybeSingle();
      checked(error, "Could not look up the account. Try again.");
      return data ? {
        id: data.id, email: data.email, appleUserId: data.apple_user_id, deletedAt: data.deleted_at,
      } : null;
    },
    async organizations(userId) {
      const { data, error } = await db.from("organizations").select("id").eq("owner_user_id", userId);
      checked(error, "Could not look up your workspaces. Try again.");
      if (!data) throw new AccountDeletionError("Could not look up your workspaces. Try again.");
      return data.map((org) => org.id as string);
    },
    async markDeleting(userId) {
      // Shares the organization row lock with atomic generation settlement.
      // Requires migration 0002; failing closed is deliberate if not deployed.
      const { error } = await db.rpc("begin_account_deletion", { p_user_id: userId });
      checked(error, "Could not start account deletion. Try again.");
    },
    async deletePhotos(orgId) { await deleteOrganizationPhotos(db, orgId); },
    async deleteProducts(orgId) {
      const { error } = await db.from("products").delete().eq("org_id", orgId);
      checked(error, "Could not delete your products. Try again.");
    },
    async deleteGenerations(orgId) {
      const traceIds: string[] = [];
      for (let start = 0; ; start += 500) {
        const { data, error: readError } = await db.from("generations")
          .select("id, langfuse_trace_id").eq("org_id", orgId)
          .order("id").range(start, start + 499);
        checked(readError, "Could not look up your generation diagnostics. Try again.");
        if (!data) throw new AccountDeletionError("Could not look up your generation diagnostics. Try again.");
        for (const generation of data) {
          if (typeof generation.langfuse_trace_id === "string" && generation.langfuse_trace_id) {
            traceIds.push(generation.langfuse_trace_id);
          }
        }
        if (data.length < 500) break;
      }
      // Keep IDs in the database until the provider accepts deletion, allowing
      // retry on a credentials/network/quota failure without losing the link.
      await deleteDiagnosticTraces(traceIds);
      const { error } = await db.from("generations").delete().eq("org_id", orgId);
      checked(error, "Could not delete your generation history. Try again.");
    },
    async anonymizeWorkspace(orgId) {
      const { error } = await db.from("organizations").update({ name: "Deleted workspace" }).eq("id", orgId);
      checked(error, "Could not remove your workspace name. Try again.");
    },
    async deleteEmailCodes(email) {
      const { error } = await db.from("email_otps").delete().eq("email", email);
      checked(error, "Could not remove your sign-in records. Try again.");
    },
    async scrubAccount(userId) {
      const { error } = await db.from("users").update({ email: null, apple_user_id: null }).eq("id", userId);
      checked(error, "Could not finish account deletion. Try again.");
    },
  };
}
