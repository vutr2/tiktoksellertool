import { SignJWT, jwtVerify } from "jose";
import { supabaseAdmin } from "./supabase.ts";
import type { SupabaseClient } from "@supabase/supabase-js";

const ISSUER = "listingforge";
const AUDIENCE = "listingforge-app";
const TTL = "90d";

function secret(): Uint8Array {
  const value = process.env.SESSION_SECRET;
  if (!value) throw new Error("SESSION_SECRET must be set.");
  return new TextEncoder().encode(value);
}

export interface SessionClaims {
  userId: string;
  orgId: string;
}

// Signs a stateless session token returned to the app as Session.token.
export async function signSession(claims: SessionClaims): Promise<string> {
  return new SignJWT({ orgId: claims.orgId })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(claims.userId)
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(TTL)
    .sign(secret());
}

// Parses "Bearer <jwt>" from an Authorization header and returns the claims, or throws.
async function verifyClaims(authorization: string | null): Promise<SessionClaims> {
  const token = authorization?.match(/^Bearer\s+(\S+)\s*$/i)?.[1];
  if (!token) throw new Error("Missing bearer token.");
  const { payload } = await jwtVerify(token, secret(), {
    issuer: ISSUER,
    audience: AUDIENCE,
    algorithms: ["HS256"],
  });
  if (!payload.sub || typeof payload.orgId !== "string") {
    throw new Error("Malformed session token.");
  }
  return { userId: payload.sub, orgId: payload.orgId };
}

/** A signed JWT alone does not outlive account deletion or workspace transfer. */
export async function verifySession(
  authorization: string | null,
  db: SupabaseClient = supabaseAdmin(),
): Promise<SessionClaims> {
  const claims = await verifyClaims(authorization);
  await verifyAccount(claims, false, db);
  return claims;
}

/** Only the deletion route accepts a tombstoned session, to retry failed cleanup. */
export async function verifyDeletionSession(
  authorization: string | null,
  db: SupabaseClient = supabaseAdmin(),
): Promise<SessionClaims> {
  const claims = await verifyClaims(authorization);
  await verifyAccount(claims, true, db);
  return claims;
}

async function verifyAccount(claims: SessionClaims, allowDeleted: boolean, db: SupabaseClient): Promise<void> {
  const { data: user, error: userError } = await db.from("users")
    .select("id, deleted_at").eq("id", claims.userId).maybeSingle();
  if (userError || !user || (!allowDeleted && user.deleted_at)) throw new Error("Account is unavailable.");
  const { data: org, error: orgError } = await db.from("organizations")
    .select("id").eq("id", claims.orgId).eq("owner_user_id", claims.userId).maybeSingle();
  if (orgError || !org) throw new Error("Workspace is unavailable.");
}

/** Recheck before completing long uploads/generations that started before deletion. */
export async function assertActiveOrganization(orgId: string, db: SupabaseClient = supabaseAdmin()): Promise<void> {
  const { data: org, error: orgError } = await db.from("organizations")
    .select("owner_user_id").eq("id", orgId).maybeSingle();
  if (orgError || !org) throw new Error("Workspace is unavailable.");
  const { data: user, error: userError } = await db.from("users")
    .select("id").eq("id", org.owner_user_id).is("deleted_at", null).maybeSingle();
  if (userError || !user) throw new Error("Account is unavailable.");
}
