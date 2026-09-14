import { supabaseAdmin } from "./supabase";
export interface AppUser {
  id: string;
  email: string | null;
}

export interface UserWithOrg {
  user: AppUser;
  orgId: string;
}

interface UpsertInput {
  appleUserId?: string | null;
  email?: string | null;
  fullName?: string | null;
}

// Finds or creates the user (by apple id, else email) and ensures they own one org.
export async function upsertUserWithOrg(input: UpsertInput): Promise<UserWithOrg> {
  const db = supabaseAdmin();

  let user = await findUser(input.appleUserId, input.email);

  if (!user) {
    const { data, error } = await db
      .from("users")
      .insert({ apple_user_id: input.appleUserId ?? null, email: input.email ?? null })
      .select("id, email")
      .single();
    if (error) throw new Error(error.message);
    user = data as AppUser;
  } else {
    // Deletion retries retain the Apple subject until cleanup finishes. Never
    // reactivate a tombstone: doing so would let an old 90-day JWT work again.
    const patch: Record<string, unknown> = {};
    if (input.email && !user.email) patch.email = input.email;
    if (input.appleUserId) patch.apple_user_id = input.appleUserId;
    if (Object.keys(patch).length > 0) {
      const { data, error } = await db
        .from("users")
        .update(patch)
        .eq("id", user.id)
        .is("deleted_at", null)
        .select("id, email")
        .single();
      if (error) throw new Error(error.message);
      user = data as AppUser;
    }
  }

  const orgId = await ensureOrg(user.id, input.fullName ?? null);
  return { user, orgId };
}

async function findUser(appleUserId?: string | null, email?: string | null): Promise<AppUser | null> {
  const db = supabaseAdmin();
  if (appleUserId) {
    const { data, error } = await db
      .from("users")
      .select("id, email, deleted_at")
      .eq("apple_user_id", appleUserId)
      .maybeSingle();
    if (error) throw new Error("Could not look up the account.");
    if (data?.deleted_at) throw new Error("Account deletion is still in progress. Return to the app and retry deletion.");
    if (data) return data as AppUser;
  }
  if (email) {
    const { data, error } = await db
      .from("users")
      .select("id, email")
      .eq("email", email)
      .is("deleted_at", null)
      .maybeSingle();
    if (error) throw new Error("Could not look up the account.");
    if (data) return data as AppUser;
  }
  return null;
}

async function ensureOrg(ownerUserId: string, fullName: string | null): Promise<string> {
  const db = supabaseAdmin();
  const { data: existing, error: lookupError } = await db
    .from("organizations")
    .select("id")
    .eq("owner_user_id", ownerUserId)
    .limit(1)
    .maybeSingle();
  if (lookupError) throw new Error("Could not load your workspace.");
  if (existing?.id) return existing.id as string;

  const name = fullName ? `${fullName}'s workspace` : "My workspace";
  const { data, error } = await db
    .from("organizations")
    .insert({ owner_user_id: ownerUserId, name })
    .select("id")
    .single();
  if (error) throw new Error(error.message);

  const orgId = data.id as string;

  // Trial credits now come exclusively from verified Apple introductory offers.
  return orgId;
}
