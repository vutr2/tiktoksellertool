// Sends the 6-digit OTP. Uses Resend's REST API via fetch (no SDK dependency).
// When RESEND_API_KEY is unset, logs the code to the server console for local dev.
export async function sendOtpEmail(email: string, code: string): Promise<void> {
  const apiKey = process.env.RESEND_API_KEY;
  const from = process.env.EMAIL_FROM || "ListingForge <login@example.com>";

  if (!apiKey) {
    console.info(`[dev] OTP for ${email}: ${code}`);
    return;
  }

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from,
      to: [email],
      subject: "Your ListingForge sign-in code",
      text: `Your ListingForge verification code is ${code}. It expires in 10 minutes.`,
    }),
  });

  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`Email provider rejected the request (${res.status}). ${detail}`);
  }
}
