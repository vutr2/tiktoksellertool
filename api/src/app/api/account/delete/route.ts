import { verifySession } from "@/lib/session";
import { supabaseAdmin } from "@/lib/supabase";
import { json, error } from "@/lib/http";

export async function POST(request: Request) {
  let claims;
  try {
    claims = await verifySession(request.headers.get("authorization"));
  } catch {
    return error("Not authorized.", 401);
  }

  const db = supabaseAdmin();

  // Delete user content (assets cascade from products), then tombstone the user
  // and scrub PII. credit_ledger/subscriptions are retained for refund audit
  // (SPEC §9/§12); they're empty until M5.
  const { data: orgs } = await db
    .from("organizations")
    .select("id")
    .eq("owner_user_id", claims.userId);
  for (const org of orgs ?? []) {
    await db.from("products").delete().eq("org_id", org.id as string);
  }

  const { error: dbError } = await db
    .from("users")
    .update({ deleted_at: new Date().toISOString(), email: null, apple_user_id: null })
    .eq("id", claims.userId);
  if (dbError) return error("Could not delete the account.", 500);

  // 200 with empty body — the client treats this as EmptyResponse.
  return json({});
}
