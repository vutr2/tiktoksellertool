import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Environment, SignedDataVerifier, type JWSTransactionDecodedPayload } from "@apple/app-store-server-library";
import { supabaseAdmin } from "./supabase.ts";
import { billingConfig } from "./billing-config.ts";

export class BillingError extends Error {
  readonly status: number;
  constructor(message: string, status = 400) { super(message); this.status = status; }
}

let cachedVerifiers: SignedDataVerifier[] | undefined;
export function storeVerifiers(): SignedDataVerifier[] {
  if (cachedVerifiers) return cachedVerifiers;
  const appID = Number(process.env.APP_STORE_APP_ID);
  const environment = process.env.APP_STORE_ENVIRONMENT;
  if (environment !== "Production" && environment !== "Sandbox") {
    throw new BillingError("Purchases are not configured yet. Please try again later.", 503);
  }
  if (environment === "Production" && (!Number.isSafeInteger(appID) || appID <= 0)) {
    throw new BillingError("Purchases are not configured yet. Please try again later.", 503);
  }
  const roots = ["AppleRootCA-G2.cer", "AppleRootCA-G3.cer"].map(name => readFileSync(join(process.cwd(), "config", "apple", name)));
  const environments = environment === "Sandbox" ? [Environment.SANDBOX] : [Environment.PRODUCTION];
  // Enable only deliberately for TestFlight/App Review testing with real Apple
  // sandbox signatures. Xcode/local unsigned transactions are NEVER trusted.
  if (environment === "Production" && process.env.APP_STORE_ALLOW_SANDBOX === "true") environments.push(Environment.SANDBOX);
  cachedVerifiers = environments.map(env => new SignedDataVerifier(roots, true, env,
    process.env.APPLE_AUDIENCE || "com.ctt.listingforge", env === Environment.PRODUCTION ? appID : undefined));
  return cachedVerifiers;
}

export async function verifyStoreTransaction(jws: string): Promise<JWSTransactionDecodedPayload> {
  for (const verifier of storeVerifiers()) {
    try { return await verifier.verifyAndDecodeTransaction(jws); } catch { /* Try next explicitly configured Apple environment. */ }
  }
  throw new BillingError("Apple could not verify this purchase. Use Restore Purchases or contact support.");
}

function anniversary(start: number, months: number): number {
  const source = new Date(start);
  const result = new Date(start);
  result.setUTCDate(1);
  result.setUTCMonth(source.getUTCMonth() + months);
  const lastDay = new Date(Date.UTC(result.getUTCFullYear(), result.getUTCMonth() + 1, 0)).getUTCDate();
  result.setUTCDate(Math.min(source.getUTCDate(), lastDay));
  return result.getTime();
}

/** Only called after Apple's verifier succeeds. Pure to test accounting dates. */
export function verifiedTransactionRecord(transaction: JWSTransactionDecodedPayload, jws: string) {
  const product = transaction.productId && billingConfig.products[transaction.productId];
  if (!product || !transaction.transactionId || !transaction.originalTransactionId || !transaction.appAccountToken ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(transaction.appAccountToken) || !transaction.purchaseDate || !transaction.signedDate ||
      ![Environment.PRODUCTION, Environment.SANDBOX].includes(transaction.environment as Environment) ||
      transaction.inAppOwnershipType === "FAMILY_SHARED" || (transaction.quantity ?? 1) !== 1) {
    throw new BillingError("This purchase cannot be linked to your account. Contact support.");
  }
  for (const timestamp of [transaction.purchaseDate, transaction.signedDate, transaction.expiresDate, transaction.revocationDate]) {
    if (timestamp !== undefined && (!Number.isSafeInteger(timestamp) || !Number.isFinite(new Date(timestamp).getTime()))) {
      throw new BillingError("Apple returned an invalid purchase date.");
    }
  }
  if (transaction.type && transaction.type !== (product.months ? "Auto-Renewable Subscription" : "Consumable")) {
    throw new BillingError("This product has an unexpected purchase type.");
  }
  const trial = transaction.offerType === 1 && transaction.offerDiscountType === "FREE_TRIAL";
  if (product.months && (!transaction.expiresDate || transaction.expiresDate <= transaction.purchaseDate)) {
    throw new BillingError("Apple did not return a valid subscription period.");
  }
  const schedule: { start: string; end: string | null; amount: number; kind: string }[] = [];
  if (!product.months) {
    schedule.push({ start: new Date(transaction.purchaseDate).toISOString(), end: null, amount: product.credits, kind: "topup" });
  } else if (trial) {
    schedule.push({ start: new Date(transaction.purchaseDate).toISOString(), end: new Date(transaction.expiresDate!).toISOString(),
      amount: billingConfig.trialCredits, kind: "trial" });
  } else {
    for (let month = 0; month < product.months; month++) {
      const start = anniversary(transaction.purchaseDate, month);
      if (start >= transaction.expiresDate!) break;
      const end = Math.min(anniversary(transaction.purchaseDate, month + 1), transaction.expiresDate!);
      schedule.push({ start: new Date(start).toISOString(), end: new Date(end).toISOString(), amount: product.credits, kind: "plan" });
    }
  }
  const prefix = transaction.environment + ":";
  return {
    transactionId: prefix + transaction.transactionId, originalTransactionId: prefix + transaction.originalTransactionId,
    productId: transaction.productId, appAccountToken: transaction.appAccountToken.toLowerCase(),
    purchaseDate: new Date(transaction.purchaseDate).toISOString(),
    expiresDate: transaction.expiresDate ? new Date(transaction.expiresDate).toISOString() : null,
    revocationDate: transaction.revocationDate ? new Date(transaction.revocationDate).toISOString() : null,
    environment: transaction.environment, signedDate: transaction.signedDate, tier: product.tier,
    creditsPerMonth: product.credits, schedule,
    payloadHash: createHash("sha256").update(jws).digest("hex"),
  };
}

export async function processStoreTransaction(orgId: string, userId: string, jws: string) {
  const record = verifiedTransactionRecord(await verifyStoreTransaction(jws), jws);
  if (record.appAccountToken !== userId.toLowerCase()) throw new BillingError("This purchase belongs to another ListingForge account.", 403);
  const { error } = await supabaseAdmin().rpc("apply_verified_apple_transaction", { p_org_id: orgId, p_transaction: record });
  if (error) throw new BillingError("Your purchase is safe with Apple, but credits could not be confirmed. Retry or restore purchases.", 503);
  return billingStatus(orgId, userId);
}

export async function billingStatus(orgId: string, userId: string) {
  const db = supabaseAdmin();
  const { error: reconcileError } = await db.rpc("reconcile_credit_periods", { p_org_id: orgId });
  if (reconcileError) throw new BillingError("Your credit balance could not be refreshed. Try again.", 503);
  const { data: report, error: balanceError } = await db.rpc("credit_balance", { p_org_id: orgId });
  const { data: subscriptions, error: subscriptionError } = await db.from("subscriptions")
    .select("tier,expires_at,status").eq("org_id", orgId).eq("status", "active").gt("expires_at", new Date().toISOString());
  if (balanceError || !report || subscriptionError) throw new BillingError("Your plan could not be loaded. Try again.", 503);
  const tiers = ["starter", "pro", "scale"];
  const tier = (subscriptions ?? []).map(s => String(s.tier)).sort((a, b) => tiers.indexOf(b) - tiers.indexOf(a))[0] ?? null;
  const allowedMarketplaces = tier === "pro" || tier === "scale" ? ["tiktok_shop", "amazon", "ebay", "etsy"] : ["tiktok_shop"];
  return { appAccountToken: userId, tier, balance: Number(report.balance), allowedMarketplaces,
    subscriptionProductIDs: Object.keys(billingConfig.products).filter(id => billingConfig.products[id].months > 0),
    topupProductID: "topup_300", costs: billingConfig.costs };
}

export async function processStoreNotification(jws: string): Promise<void> {
  let notification;
  let chosenVerifier;
  for (const verifier of storeVerifiers()) {
    try { notification = await verifier.verifyAndDecodeNotification(jws); chosenVerifier = verifier; break; }
    catch { /* Only Apple-verified notifications are processed. */ }
  }
  if (!notification || !chosenVerifier || !notification.notificationUUID) throw new BillingError("Invalid Apple notification.");
  if (notification.notificationType === "TEST") return;
  const signedTransaction = notification.data?.signedTransactionInfo;
  if (!signedTransaction) return; // No transaction or entitlement event to process.
  const transaction = await chosenVerifier.verifyAndDecodeTransaction(signedTransaction);
  const record = verifiedTransactionRecord(transaction, signedTransaction);
  const db = supabaseAdmin();
  const { data: existing, error: existingError } = await db.from("apple_transactions").select("org_id").eq("transaction_id", record.transactionId).maybeSingle();
  if (existingError) throw new BillingError("Purchase account could not be loaded.", 503);
  let orgId = existing?.org_id;
  if (!orgId) {
    const { data: orgs, error } = await db.from("organizations").select("id").eq("owner_user_id", record.appAccountToken).limit(2);
    if (error || orgs?.length !== 1) throw new BillingError("Purchase account could not be resolved yet.", 503);
    orgId = orgs[0].id;
  }
  const signedRenewal = notification.data?.signedRenewalInfo;
  const renewal = signedRenewal ? await chosenVerifier.verifyAndDecodeRenewalInfo(signedRenewal) : null;
  const { error } = await db.rpc("apply_verified_apple_transaction", {
    p_org_id: orgId, p_transaction: { ...record, signedDate: Math.max(record.signedDate, notification.signedDate ?? 0), autoRenewStatus: renewal?.autoRenewStatus === undefined ? null : renewal.autoRenewStatus === 1 },
    p_notification: { id: notification.notificationUUID, type: notification.notificationType, subtype: notification.subtype ?? null },
  });
  if (error) throw new BillingError("Notification could not be applied. Retry later.", 503);
}
