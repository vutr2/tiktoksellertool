import { verifyDeletionSession } from "@/lib/session";
import { AccountDeletionError, deleteAccount, type DeleteAccountInput } from "@/lib/account-deletion";
import { json, error } from "@/lib/http";

export async function POST(request: Request) {
  let claims;
  try {
    claims = await verifyDeletionSession(request.headers.get("authorization"));
  } catch {
    return error("Not authorized.", 401);
  }

  let input: DeleteAccountInput = {};
  try {
    const text = await request.text();
    if (text) {
      const body: unknown = JSON.parse(text);
      if (!body || typeof body !== "object" || Array.isArray(body)) return error("Invalid request body.");
      const value = body as Record<string, unknown>;
      if ((value.identityToken !== undefined && typeof value.identityToken !== "string") ||
          (value.authorizationCode !== undefined && typeof value.authorizationCode !== "string") ||
          (value.skipAppleRevocation !== undefined && typeof value.skipAppleRevocation !== "boolean")) {
        return error("Invalid deletion confirmation.");
      }
      input = value as DeleteAccountInput;
    }
  } catch {
    return error("Invalid request body.");
  }

  try {
    return json(await deleteAccount(claims.userId, input));
  } catch (failure) {
    if (failure instanceof AccountDeletionError) return error(failure.message, failure.status);
    return error("Account deletion could not finish. Please retry from Settings.", 500);
  }
}
