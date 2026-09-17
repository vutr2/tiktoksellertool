import { createHash } from "node:crypto";
import { supabaseAdmin } from "@/lib/supabase";
import { upsertUserWithOrg } from "@/lib/users";
import { signSession } from "@/lib/session";
import { reviewAccount } from "@/lib/env";
import { balanceOf, appendEntry } from "@/lib/credits";
import { json, error } from "@/lib/http";

/** How many demo credits the review account is kept topped up to. */
const REVIEW_CREDITS = 300;

/** Signs in the App Review demo account and keeps it stocked with credits. */
async function signInReviewAccount(email: string) {
  const { user, orgId } = await upsertUserWithOrg({ email });
  const { balance } = await balanceOf(orgId);
  if (balance < 50) await appendEntry(orgId, REVIEW_CREDITS, "subscription.grant");
  const token = await signSession({ userId: user.id, orgId });
  return json({ token, user: { id: user.id, email: user.email } });
}

const MAX_ATTEMPTS = 5;

function hashCode(email: string, code: string): string {
  return createHash("sha256").update(`${email}:${code}`).digest("hex");
}

interface Body {
  email?: string;
  code?: string;
}

export async function POST(request: Request) {
  let body: Body;
  try {
    body = await request.json();
  } catch {
    return error("Invalid request body.");
  }
  const email = body.email?.trim().toLowerCase();
  const code = body.code?.trim();
  if (!email || !code) return error("Email and code are required.");

  // App Review demo account: accept the fixed code, bypassing the emailed OTP.
  if (reviewAccount.matches(email)) {
    if (code !== reviewAccount.code()) return error("That code is incorrect.");
    try {
      return await signInReviewAccount(email);
    } catch (e) {
      return error(e instanceof Error ? e.message : "Verification failed.", 500);
    }
  }

  const db = supabaseAdmin();
  const { data: otp } = await db
    .from("email_otps")
    .select("id, code_hash, expires_at, attempts, consumed_at")
    .eq("email", email)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!otp || otp.consumed_at) return error("No pending code for this email. Request a new one.");
  if (new Date(otp.expires_at as string).getTime() < Date.now()) {
    return error("That code expired. Request a new one.");
  }
  if ((otp.attempts as number) >= MAX_ATTEMPTS) return error("Too many attempts. Request a new code.");

  if (otp.code_hash !== hashCode(email, code)) {
    await db.from("email_otps").update({ attempts: (otp.attempts as number) + 1 }).eq("id", otp.id);
    return error("That code is incorrect.");
  }

  await db.from("email_otps").update({ consumed_at: new Date().toISOString() }).eq("id", otp.id);

  try {
    const { user, orgId } = await upsertUserWithOrg({ email });
    const token = await signSession({ userId: user.id, orgId });
    return json({ token, user: { id: user.id, email: user.email } });
  } catch (e) {
    return error(e instanceof Error ? e.message : "Verification failed.", 500);
  }
}
