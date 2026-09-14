import { verifyAppleIdentityToken } from "@/lib/apple";
import { upsertUserWithOrg } from "@/lib/users";
import { signSession } from "@/lib/session";
import { json, error } from "@/lib/http";

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
<<<<<<< HEAD
  if (!body || typeof body !== "object" || Array.isArray(body)) return error("Invalid request body.");
=======
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
  if (typeof body.identityToken !== "string" || !body.identityToken) return error("Missing identity token.");

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
