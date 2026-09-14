# App Store submission review — 14 September 2026

Status: implementation and local validation in progress. This is not an App Review approval or a production deployment.

## Implemented

- Account-scoped SwiftData and file caches, stale-request guards, durable capture drafts, upload of all captured angles with immutable retry IDs and raw PNG bodies. Cutouts preserve alpha and fit the server's 4 MiB limit.
- Durable generation request IDs on iOS. Server reservations, asset/result persistence, usage accounting and credit debit settle atomically. A lost response can recover the completed result without another debit.
- Apple identity verification and checked, retryable account deletion, including storage cleanup, token revocation with explicit manual fallback, and recorded trace deletion. Purchase audit records remain retained; see ACCOUNT_DELETION.md.
- Explicit AI-sharing consent before generation, withdrawal in Settings, linked purchase-history privacy declaration, report-content endpoint and visible failure/compliance information on reopened listings.
- StoreKit transaction listener at app initialization, account-bound purchases, restore, native SwiftUI plan controls, localized Apple prices, subscription management and server-enforced marketplace tiers. Transactions finish only after a decoded server acknowledgment. No unsigned Xcode transactions are trusted by the real backend.
- Apple SDK verification, environment-scoped transaction IDs, idempotent grants, monthly annual-plan periods, once-per-account introductory credits, attributed spending, refunds and refund reversals, stale notification guards and immutable ledger rows. Existing administrative credits remain spendable. New account creation no longer grants an unverified trial.
- Release builds reject missing/non-public API, privacy, support and terms URLs. Camera configuration/capture/start/stop/metering share one serial hardware queue.
- Backend PostCSS patched within major version 8; npm audit reports zero vulnerabilities at this review.

## Local validation

Run from the repository root unless noted:

```sh
npm --prefix api run typecheck
npm --prefix api test
python3 api/scripts/test-generation-db.py
python3 -m unittest discover -s ios/scripts -p 'test_*.py'
make gen
xcodebuild -project ios/ListingForge.xcodeproj -scheme ListingForge \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
xcodebuild -project ios/ListingForge.xcodeproj -scheme ListingForgeStoreKitTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:ListingForgeTests/StoreKitIntegrationTests
```

The database script creates a disposable socket-only PostgreSQL cluster, applies all migrations, and never reads `.env` or connects to an existing database. It covers concurrent reservation/purchase replay, transactional rollback, immutable retries, stale leases, deletion, trial uniqueness, annual boundaries, plan-first allocation, legacy credits, negative refunds, refund reversal, cross-account replay and server-only RPC privileges.

API: 91 tests passed. The isolated Next.js production build passed; `/api/health` and `/api/rules` returned 200 on local port 3002, and unauthenticated billing/credits returned 401. The deployed bundle trace includes the Apple trust roots and credit catalog.

iOS: the latest ordinary suite passed 134 tests with 0 failures and 2 explicit skips. The app was installed, launched and visually checked on Simulator. Purchase acknowledgment and generation recovery unit tests passed. StoreKit integration currently fails in the existing iOS 26.5 Simulator with `.notEntitled` (catalog lookup also returned no products). The same purchase test also failed on a fresh disposable iOS 26.5 Simulator; no alternate runtime is installed. Do not describe the actual StoreKit purchase/restore flow as validated until this test and real Apple Sandbox tests pass. The local StoreKit test is explicitly opt-in through its separate scheme; ordinary unit tests do not silently certify it.

## Required before submission

1. ~~Resolve the credit-expiry business rule.~~ **Resolved by the owner on
   2026-09-15: paid credits never expire; only feature access ends with the
   subscription.** Implemented in `0005_paid_credits_do_not_expire.sql` — plan
   grants no longer receive an `expires_at`, and existing unexpired plan grants
   have theirs cleared. Top-ups already had none. The free trial still expires,
   since Guideline 3.1.1 concerns purchased content. Feature access was already
   read from the `subscriptions` table rather than the balance, so it needed no
   change. SPEC §6 updated to match.

   Verified against a disposable PostgreSQL cluster with every migration
   applied: an annual plan now reaches 1100 credits (Jan 400 + top-up 300 +
   Mar 400) and stays there, with zero `subscription.expiry` ledger rows.
   **Migration 0005 has not been applied to the live Supabase project.**
2. Supply real public HTTPS backend, Privacy Policy, Terms and support URLs. Complete matching App Privacy answers, retention policy and support contact. Release validation deliberately fails while these are absent.
3. Configure App Store Connect products/group levels, introductory offers and agreements; provide numeric APP_STORE_APP_ID and verified bundle/environment settings. Configure V2 notifications at `/api/billing/notifications`. Same-tier monthly/annual products belong at the same group level; do not advertise bulk workflows that are not implemented.
4. Validate real Apple Sandbox/TestFlight purchase, interrupted purchase, pending approval, restore after reinstall/account switch, renewal, refund and notifications against a staging database. Local StoreKit signatures are deliberately rejected by the real server. Do not enable Billing Grace Period until its entitlement behavior is implemented and tested; the current backend uses the verified transaction expiration.
5. Apply approved migrations to staging and validate before any separate production deployment. No migration has been applied to production here. Existing backend routes now depend on the new functions.
6. Complete physical-device camera/permission/interruption, email delivery, Apple sign-in/deletion and low-memory checks. Simulator compilation cannot validate real camera hardware or Apple account configuration.
7. Complete a signed Release archive/validation, screenshots, metadata, reviewer account and a running review backend. Product images/background generation and bulk operations must not be promised where absent.

## Reports and operations

Reports are stored in `products.attributes.contentReports` after ownership validation. No Slack/email is sent automatically. The operator must establish a review workflow and response policy before advertising moderation/support turnaround. Account deletion also deletes those product-bound reports. Historical provider traces that lack recorded IDs require operator/provider cleanup; do not promise automatic deletion for them.

Billing server configuration is documented in `api/.env.example`. Public Apple roots are bundled under `api/config/apple`; no private Apple signing key is included. Native SwiftUI purchase controls call StoreKit directly so the app controls the server-acknowledgment/finish ordering.
