import test from "node:test";
import assert from "node:assert/strict";
import { Environment, type JWSTransactionDecodedPayload } from "@apple/app-store-server-library";
import { verifiedTransactionRecord, verifyStoreTransaction } from "../src/lib/billing.ts";

function fixture(overrides: Partial<JWSTransactionDecodedPayload> = {}): JWSTransactionDecodedPayload {
  return { transactionId: "123", originalTransactionId: "122", productId: "starter_monthly",
    appAccountToken: "00000000-0000-4000-8000-000000000001", purchaseDate: Date.parse("2026-01-31T12:00:00Z"),
    expiresDate: Date.parse("2026-02-28T12:00:00Z"), signedDate: Date.parse("2026-01-31T12:00:00Z"),
    environment: Environment.SANDBOX, ...overrides };
}

test("annual purchase grants monthly amounts with clamped calendar anniversaries", () => {
  const record = verifiedTransactionRecord(fixture({ productId: "pro_annual", expiresDate: Date.parse("2027-01-31T12:00:00Z") }), "test");
  assert.equal(record.schedule.length, 12);
  assert.ok(record.schedule.every(period => period.amount === 1100));
  assert.equal(record.schedule[0].end, "2026-02-28T12:00:00.000Z");
  assert.equal(record.schedule[1].start, record.schedule[0].end);
  assert.equal(record.schedule[1].end, "2026-03-31T12:00:00.000Z");
  assert.equal(record.schedule[11].end, "2027-01-31T12:00:00.000Z");
});

test("only verified free introductory offers use the trial credit amount", () => {
  const free = verifiedTransactionRecord(fixture({ offerType: 1, offerDiscountType: "FREE_TRIAL" }), "test");
  assert.equal(free.schedule[0].amount, 100);
  assert.equal(free.schedule[0].kind, "trial");
  const paid = verifiedTransactionRecord(fixture({ offerType: 1, offerDiscountType: "PAY_AS_YOU_GO" }), "test");
  assert.equal(paid.schedule[0].amount, 400);
});

test("top-ups never expire and transaction IDs are environment scoped", () => {
  const record = verifiedTransactionRecord(fixture({ productId: "topup_300", expiresDate: undefined }), "test");
  assert.equal(record.schedule[0].end, null);
  assert.equal(record.schedule[0].amount, 300);
  assert.equal(record.transactionId, "Sandbox:123");
});

test("reject unknown products, family-shared credits and missing or malformed account binding", () => {
  for (const overrides of [{ productId: "arbitrary" }, { appAccountToken: undefined },
    { appAccountToken: "------------------------------------" }, { inAppOwnershipType: "FAMILY_SHARED" },
    { quantity: 2 }, { expiresDate: 1 }, { environment: Environment.XCODE }]) {
    assert.throws(() => verifiedTransactionRecord(fixture(overrides), "test"));
  }
});

test("unsigned local StoreKit payloads cannot authorize server credits", async () => {
  process.env.APP_STORE_ENVIRONMENT = "Sandbox";
  const forged = Buffer.from(JSON.stringify(fixture())).toString("base64url");
  await assert.rejects(verifyStoreTransaction("eyJhbGciOiJub25lIn0." + forged + "."));
});
