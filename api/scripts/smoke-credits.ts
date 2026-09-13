// Exercises the ledger against the live database.
// Run: node --env-file=.env scripts/smoke-credits.ts
import { supabaseAdmin } from "../src/lib/supabase.ts";
import {
  InsufficientCreditsError, appendEntry, assertCanAfford,
  balanceOf, chargeCredits, refundCredits,
} from "../src/lib/credits.ts";

const db = supabaseAdmin();
const { data: orgs } = await db.from("organizations").select("id").limit(1);
const orgId = orgs?.[0]?.id as string;
if (!orgId) { console.log("no organization to test against"); process.exit(1); }

const before = await balanceOf(orgId);
console.log("start balance:", before.balance, `(${before.entryCount} entries)`);

await appendEntry(orgId, 100, "subscription.grant");
console.log("after grant  :", (await balanceOf(orgId)).balance);

await chargeCredits(orgId, 2, "generation.script");
console.log("after charge :", (await balanceOf(orgId)).balance, "(ad script = 2 credits)");

try {
  await assertCanAfford(orgId, 1_000_000);
  console.log("❌ overspend was allowed");
} catch (e) {
  if (e instanceof InsufficientCreditsError) {
    console.log("overspend    : refused —", e.message);
  } else throw e;
}

await refundCredits(orgId, 2);
const after = await balanceOf(orgId);
console.log("after refund :", after.balance);

console.log("--- integrity ---");
console.log("  derived vs recorded:", after.balance, "vs", after.recordedBalanceAfter,
            after.drifted ? "❌ DRIFT" : "✅ khớp");
console.log("  entries added      :", after.entryCount - before.entryCount, "(grant, charge, refund)");
console.log("  free action writes :", (await chargeCredits(orgId, 0, "generation.script")) === null ? "nothing ✅" : "❌ a row");
console.log("  net effect         :", after.balance - before.balance, "(100 granted, 2 charged, 2 refunded)");
