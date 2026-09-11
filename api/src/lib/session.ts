import { SignJWT, jwtVerify } from "jose";

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
export async function verifySession(authorization: string | null): Promise<SessionClaims> {
  const token = authorization?.replace(/^Bearer\s+/i, "").trim();
  if (!token) throw new Error("Missing bearer token.");
  const { payload } = await jwtVerify(token, secret(), {
    issuer: ISSUER,
    audience: AUDIENCE,
  });
  if (!payload.sub || typeof payload.orgId !== "string") {
    throw new Error("Malformed session token.");
  }
  return { userId: payload.sub, orgId: payload.orgId };
}
