import { verifySession } from "@/lib/session";
import { balanceOf } from "@/lib/credits";
import { json, error } from "@/lib/http";

/** The seller's credit balance — shown before they commit to a generation. */
export async function GET(request: Request) {
  let claims;
  try {
    claims = await verifySession(request.headers.get("authorization"));
  } catch {
    return error("Not authorized.", 401);
  }

  try {
    const report = await balanceOf(claims.orgId);
    return json({
      balance: report.balance,
      // Surfaced rather than hidden: a mismatch between the summed ledger and
      // the recorded balance_after is an accounting fault worth seeing.
      drifted: report.drifted,
    });
  } catch {
    return error("Could not read your credit balance.", 500);
  }
}
