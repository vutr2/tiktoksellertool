import { createHash, randomInt } from "node:crypto";
import { supabaseAdmin } from "@/lib/supabase";
import { sendOtpEmail } from "@/lib/email";
import { reviewAccount } from "@/lib/env";
import { json, error } from "@/lib/http";

const CODE_TTL_MINUTES = 10;

function isValidEmail(value: string): boolean {
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value);
}

function hashCode(email: string, code: string): string {
  return createHash("sha256").update(`${email}:${code}`).digest("hex");
}

interface Body {
  email?: string;
}

export async function POST(request: Request) {
  let body: Body;
  try {
    body = await request.json();
  } catch {
    return error("Invalid request body.");
  }
  const email = body.email?.trim().toLowerCase();
  if (!email || !isValidEmail(email)) return error("Enter a valid email address.");

  // App Review demo account: accept a fixed code, so send nothing here.
  if (reviewAccount.matches(email)) return json({});

  const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
  const expiresAt = new Date(Date.now() + CODE_TTL_MINUTES * 60_000).toISOString();

  const db = supabaseAdmin();
  const { error: dbError } = await db.from("email_otps").insert({
    email,
    code_hash: hashCode(email, code),
    expires_at: expiresAt,
  });
  if (dbError) return error("Could not start email sign-in.", 500);

  try {
    await sendOtpEmail(email, code);
  } catch {
    return error("Could not send the verification email.", 502);
  }

  // 200 with empty body — the client treats this as EmptyResponse.
  return json({});
}
