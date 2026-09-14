import { BillingError, processStoreNotification } from "@/lib/billing";
import { readLimitedBody } from "@/lib/products";
import { json, error } from "@/lib/http";

export async function POST(request: Request) {
  let body;
  try { body = JSON.parse((await readLimitedBody(request, 131072)).toString("utf8")); }
  catch { return error("Invalid notification."); }
  if (typeof body?.signedPayload !== "string") return error("A signed notification is required.");
  try { await processStoreNotification(body.signedPayload); return json({ received: true }); }
  catch (e) { return error(e instanceof BillingError ? e.message : "Could not process notification.", e instanceof BillingError ? e.status : 503); }
}
