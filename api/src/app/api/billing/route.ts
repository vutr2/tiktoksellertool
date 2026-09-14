import { verifySession } from "@/lib/session";
import { BillingError, billingStatus, processStoreTransaction } from "@/lib/billing";
import { readLimitedBody } from "@/lib/products";
import { json, error } from "@/lib/http";

export async function GET(request: Request) {
  let claims;
  try { claims = await verifySession(request.headers.get("authorization")); }
  catch { return error("Not authorized.", 401); }
  try { return json(await billingStatus(claims.orgId, claims.userId)); }
  catch (e) { return error(e instanceof BillingError ? e.message : "Could not load your plan.", e instanceof BillingError ? e.status : 503); }
}

export async function POST(request: Request) {
  let claims;
  try { claims = await verifySession(request.headers.get("authorization")); }
  catch { return error("Not authorized.", 401); }
  let body;
  try { body = JSON.parse((await readLimitedBody(request, 65536)).toString("utf8")); }
  catch { return error("Could not read the purchase."); }
  if (typeof body?.signedTransaction !== "string") return error("An Apple-signed transaction is required.");
  try { return json(await processStoreTransaction(claims.orgId, claims.userId, body.signedTransaction)); }
  catch (e) { return error(e instanceof BillingError ? e.message : "Could not verify your purchase.", e instanceof BillingError ? e.status : 503); }
}
