import { verifyAppleIdentityToken } from "@/lib/apple";
import { upsertUserWithOrg } from "@/lib/users";
import { signSession } from "@/lib/session";
import { rateLimit, clientIp, RATE_LIMITS } from "@/lib/rate-limit";
import { json, error, tooMany } from "@/lib/http";

interface Body {
  identityToken?: string;
  authorizationCode?: string | null;
  email?: string | null;
  fullName?: string | null;
}

export async function POST(request: Request) {
  let body: Body;
  try {
    body = await request.json();
  } catch {
    return error("Invalid request body.");
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) return error("Invalid request body.");
  if (typeof body.identityToken !== "string" || !body.identityToken) return error("Missing identity token.");

  const throttle = await rateLimit(`apple:ip:${clientIp(request)}`, RATE_LIMITS.applePerIp);
  if (!throttle.allowed) return tooMany("Too many sign-in attempts. Try again later.", throttle.retryAfterSeconds);

  let identity;
  try {
    identity = await verifyAppleIdentityToken(body.identityToken);
  } catch {
    return error("Apple sign-in could not be verified.", 401);
  }

  try {
    const { user, orgId } = await upsertUserWithOrg({
      appleUserId: identity.appleUserId,
      email: identity.email,
      fullName: typeof body.fullName === "string" ? body.fullName.trim().slice(0, 200) || null : null,
    });
    const token = await signSession({ userId: user.id, orgId });
    return json({ token, user: { id: user.id, email: user.email } });
  } catch (e) {
    return error(e instanceof Error ? e.message : "Sign-in failed.", 500);
  }
}
