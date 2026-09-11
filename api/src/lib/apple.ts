import { createRemoteJWKSet, jwtVerify } from "jose";

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
  });
  if (!payload.sub) throw new Error("Apple token missing subject.");
  const email = typeof payload.email === "string" ? payload.email : null;
  return { appleUserId: payload.sub, email };
}
