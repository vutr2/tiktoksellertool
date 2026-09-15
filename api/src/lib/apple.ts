import { createRemoteJWKSet, importPKCS8, jwtVerify, SignJWT } from "jose";

const APPLE_ISSUER = "https://appleid.apple.com";
const jwks = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));

export interface AppleIdentity {
  appleUserId: string;
  email: string | null;
}

// Verifies a native Sign in with Apple identity token against Apple's public
// keys. Audience is the app bundle id (APPLE_AUDIENCE).
export async function verifyAppleIdentityToken(identityToken: string): Promise<AppleIdentity> {
  const audience = process.env.APPLE_AUDIENCE || "com.ctt.listingforge";
  const { payload } = await jwtVerify(identityToken, jwks, {
    issuer: APPLE_ISSUER,
    audience,
    algorithms: ["RS256"],
  });
  if (!payload.sub) throw new Error("Apple token missing subject.");
  // Only Apple's verified claim may link to an existing email account. A
  // caller-supplied email (or an unverified claim) is not proof of ownership.
  const verifiedEmail = payload.email_verified === true || payload.email_verified === "true";
  const email = verifiedEmail && typeof payload.email === "string"
    ? payload.email.trim().toLowerCase() : null;
  return { appleUserId: payload.sub, email };
}

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} must be configured for Apple account deletion.`);
  return value;
}

async function appleClientSecret(): Promise<string> {
  const privateKey = await importPKCS8(required("APPLE_PRIVATE_KEY").replace(/\\n/g, "\n"), "ES256");
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: required("APPLE_KEY_ID") })
    .setIssuer(required("APPLE_TEAM_ID"))
    .setSubject(process.env.APPLE_AUDIENCE || "com.ctt.listingforge")
    .setAudience(APPLE_ISSUER)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(privateKey);
}

export class AppleRevocationError extends Error {}

/**
 * Uses a fresh native authorization code so legacy users need no stored refresh
 * token or schema migration. Code exchange and revocation stay on the server;
 * none of Apple's tokens are logged or returned to the app.
 */
export async function revokeAppleAuthorization(
  identityToken: string,
  authorizationCode: string,
  expectedAppleUserId: string,
  dependencies = { verifyIdentity: verifyAppleIdentityToken, fetch: globalThis.fetch, clientSecret: appleClientSecret },
): Promise<void> {
  const identity = await dependencies.verifyIdentity(identityToken);
  if (identity.appleUserId !== expectedAppleUserId) {
    throw new AppleRevocationError("Use the Apple Account linked to this Listing Force account.");
  }
  const credentials = {
    client_id: process.env.APPLE_AUDIENCE || "com.ctt.listingforge",
    client_secret: await dependencies.clientSecret(),
  };
  const exchanged = await dependencies.fetch(`${APPLE_ISSUER}/auth/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ ...credentials, grant_type: "authorization_code", code: authorizationCode }),
    signal: AbortSignal.timeout(15_000),
  });
  if (!exchanged.ok) throw new AppleRevocationError("Apple authorization expired. Sign in with Apple again to delete your account.");
  const tokens = await exchanged.json() as Record<string, unknown>;
  if (typeof tokens.id_token !== "string") throw new AppleRevocationError("Apple did not return a verified identity.");
  // A valid code for a DIFFERENT Apple user must never revoke that user's grant.
  const exchangedIdentity = await dependencies.verifyIdentity(tokens.id_token);
  if (exchangedIdentity.appleUserId !== expectedAppleUserId) {
    throw new AppleRevocationError("Use the Apple Account linked to this Listing Force account.");
  }
  const token = typeof tokens.refresh_token === "string" ? tokens.refresh_token : tokens.access_token;
  if (typeof token !== "string" || !token) throw new AppleRevocationError("Apple did not return a token for revocation.");
  const revoked = await dependencies.fetch(`${APPLE_ISSUER}/auth/revoke`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      ...credentials, token,
      token_type_hint: typeof tokens.refresh_token === "string" ? "refresh_token" : "access_token",
    }),
    signal: AbortSignal.timeout(15_000),
  });
  if (!revoked.ok) throw new AppleRevocationError("Apple access could not be revoked. Try again or choose manual revocation.");
}
