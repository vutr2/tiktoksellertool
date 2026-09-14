Billing schema proposed for owner approval — 14 September 2026

This is a proposal, not an applied migration. The approved generation_requests
migration covers generation reservations/settlement; it does not make Apple
purchases safe or idempotent. Existing subscriptions and the append-only ledger
remain authoritative alongside the following proposed records.

| New table | Key fields and purpose |
| --- | --- |
| apple_transactions | transaction_id primary key; original_transaction_id; org_id; product_id; app_account_token; purchase_date; expires_date; revocation_date; environment; verified payload hash. One verified Apple renewal/top-up can grant only once. |
| apple_notifications | notification_uuid primary key; transaction_id; notification_type; subtype; received_at; processed_at; processing_error. Retry notifications without applying the same refund twice. |
| credit_grants | id UUID primary key; org_id; transaction_id; billing_period_start/end; kind plan/topup/trial; amount; expires_at nullable; unique(transaction_id,billing_period_start,kind). Attribute each spend and refund to its source; purchased consumable top-ups do not expire. |
| credit_allocations | ledger_entry_id + grant_id composite key; amount. Spend plan credits before top-ups and determine the remaining amount when a plan period expires or Apple refunds a transaction. |

Extend subscriptions with verified app_account_token/account linkage and renewal
state only if those cannot be derived from apple_transactions. Do not use
original_transaction_id as a unique renewal id: Apple reuses it across renewals.

Service-role-only functions, using the same organization row lock as generation:

- apply_verified_apple_transaction: associate ownership using verified
  appAccountToken, upsert subscription state, apply one eligible grant.
- reconcile_credit_periods: grant annual plans one billing month at a time;
  append expiry adjustments for unused plan grants; allocate the 100-credit trial
  once according to verified introductory offer eligibility.
- settle_generation: extend approved settlement to allocate the debit to plan
  then top-up grants without exceeding the active reservation.
- apply_verified_apple_notification: deduplicate, update entitlement state and
  append refund reversal against the affected grant. Refunds may make the balance
  negative; subsequent generation is blocked until resolved.

Verify all transaction/notification signatures server-side using Apple's trust
roots and expected bundle/app/environment. No grants from client-reported product,
price, balance or transaction JSON. The app finishes a StoreKit transaction only
after the backend confirms its durable processing. Restore replays verified
transactions safely, without granting additional credits.

Before enabling purchases: test duplicated/out-of-order events, concurrent
generation/purchase/refund, annual monthly boundaries, introductory offer once,
plan-first spending, top-up persistence, deleted-account notifications, and
cross-account restoration in a disposable database. This proposal does not
authorize deploying migrations or creating products in App Store Connect.
