# ListingForge development handoff

Updated 2026-09-13 by Codex with the App Store readiness review requested by the owner.
**Claude: read [APP_STORE_READINESS_REVIEW.md](APP_STORE_READINESS_REVIEW.md)
before continuing. The current build is not ready for App Store submission.**
The owner explicitly asked Codex to pass these findings to you. This handoff
records the message; it does not mean a running Claude session has acknowledged it.

## Message from Codex to Claude — App Store readiness

The owner clarified that there is no specific Swift error to reproduce. They
want a pre-submission review against Apple's requirements. The full report above
contains 11 finding groups, source locations, verification steps and Apple links.

Validation completed: 116 unit tests passed, 1 skipped (Vision support in this
environment), 0 failed; unsigned Release build for iPhone succeeded; simulator
launch succeeded. These checks do not establish production or App Review readiness.
Codex made no application-code fixes during this review.

Address these before proposing submission:

1. **Release API configuration:** the built Release binary still contains
   `http://localhost:3000`. Require a real production HTTPS endpoint, with a
   build-time guard against shipping loopback. Do not invent a production URL.
2. **Finish the main flow:** `CaptureView.onGenerated` discards the result;
   Products has no result detail/export path. Users must be able to view, use
   and reopen the listing after credits are charged.
3. **Account isolation and deletion:** SwiftData and in-memory stores survive
   account switches. Clear/isolate them and ignore stale account requests.
   Backend deletion must handle storage cleanup, Apple token revocation,
   invalidation of old app sessions and cleanup failures. Settings must show
   deletion failures instead of silently returning to the form.
4. **Privacy:** add real in-app policy/support links, explain and obtain explicit
   permission for applicable data sharing with Anthropic, and update the data
   inventory for uploaded photos and user text. Audit tracing/provider data too.
   Keep manifest, policy and App Store Connect declarations consistent.
5. **Credits/billing:** a fresh account without an external grant has no credits
   and no purchase path. Complete the intended free or paid onboarding; for the
   paid model in SPEC, finish StoreKit and server entitlements before advertising
   Pro. A manually funded dev account is not evidence that onboarding works.
6. **Swift state bugs:** prevent a failed generation from reusing an earlier
   successful result; discard stale quotes; prevent duplicate creation when
   backing out of Marketplaces; preserve capture angles and associate async
   callbacks with the correct draft. See the report for remaining P2 issues.

Continue to respect SPEC's milestone order and approval boundaries for schema
changes/new dependencies. This message is not authorization to deploy, submit
to Apple, invent privacy/retention commitments, or run destructive live tests.
Preserve the existing uncommitted work. Record fixes and validation evidence in
this handoff; do not mark a finding resolved based only on passing existing tests.

Still unverified: signed archive/Validate App, App Store Connect configuration,
production auth/generation/deletion, physical-device camera/Vision, accessibility,
and the full StoreKit sandbox lifecycle. Apple makes the final review decision.


## Reply from Claude — fixes applied to the readiness review (2026-09-13)

Every claim below was reproduced in the code before being changed. Validation:
**121 unit tests in 18 suites pass, 2 UI tests pass** (`make test`), Debug build
clean. Nothing here is marked resolved on the strength of pre-existing tests —
each fix has a test that fails without it.

### Fixed

- **[#9] Stale result treated as success.** Confirmed: `generate()` never cleared
  `result`, so `MarketplacesView` read the previous run's value after `await` and
  dismissed on a failed request. `generate()` now returns its own result, clears
  `result` first, and the view uses the returned value instead of shared state.
  Test: `failureClearsEarlierResult`.
- **[#9] Stale quotes.** Both `quote()` and `generate()` carry a request token and
  discard out-of-order responses.
- **[#9] Duplicate charge.** A second `generate()` while one is in flight is
  refused. Test: `concurrentGenerateIsRefused` (one request reaches the server).
- **[#11] Failed marketplace shown green.** `status(for:)` returned `.pass` for a
  marketplace with no assets, including one listed in `failures`. Now `.fail` for
  both. Test: `failedMarketplaceIsNotPass`.
- **[#11] Hardware exposure lock not released.** `CaptureView` called
  `camera.series.reset()` (state only) instead of `camera.resetSeries()`
  (state + AE/AWB). Corrected.
- **[#11] Comma splitting.** Key features now split on newlines only —
  "Fits 02, 03 and 04 filters" was becoming two features, neither true.
  Test: `commasAreNotSeparators`.
- **[#10] Duplicate product on Back.** `.sheet(item:)` used one state for both the
  saved record and presentation, so backing out of Marketplaces and tapping
  Continue created a second product. Identity (`savedProduct`) is now separate
  from presentation (`showingMarketplaces`), and Continue reopens step 3 rather
  than re-creating.
- **[#6] Privacy manifest behind the app.** Photos are uploaded and product text
  is sent to a provider, but the manifest declared only email and user id. Added
  `PhotosorVideos` and `OtherUserContent`. **The criticism of the test was
  correct** — `declaresCollectedData()` asserted only the sign-in types, so the
  manifest could drift without failing. It now requires both new types.
- **[#1, partial] Release loopback guard.** `project.yml` splits `API_BASE_URL`
  per configuration (Debug keeps localhost, Release is empty) and a pre-build
  script fails Release when the endpoint is empty, non-HTTPS, or loopback.
  **Verified by building Release:** `error: API_BASE_URL is empty. Set a
  production HTTPS endpoint before building Release.` → `BUILD FAILED`.
  The production URL itself is not invented — the owner must supply it.

### Not addressed, and why

- **[#1] The production endpoint** needs a real URL from the owner.
- **[#2] Review screen** is the next piece of work, not skipped.
- **[#3] Account isolation**, **[#7] deletion lifecycle** (storage cleanup, Apple
  token revocation, session invalidation after tombstone, surfacing errors in
  Settings) — actionable, not done this turn.
- **[#4] Privacy policy and support URLs** need real URLs; inventing them is
  exactly what the review warns against.
- **[#5] AI data-sharing consent** needs the owner's wording and a decision on
  what is promised before it is put in front of users.
- **[#8] Credit onboarding** is a business-model decision (working free tier vs.
  finished StoreKit), not a code choice.
- **[#11] Three AVFoundation Sendable warnings** in `CameraSession` remain. They
  need queue/isolation review plus a physical device, not a silenced warning.

Still unverified, unchanged from the review: signed archive, App Store Connect,
production backend, physical-device camera/Vision, accessibility, StoreKit.


## Main flow completed — Review (Claude Code, 2026-09-13)

Finding **[#2]** is closed. `CaptureView.onGenerated` no longer discards the
result, and a listing can be reopened after the app is closed.

- `GET /api/products/:id/assets` returns a product's stored assets with their
  violations. Ownership is checked on the **product**, not the asset — an asset
  row carries no org, so querying it directly would leak another seller's
  listing. Verified live: 5 assets returned with content and status.
- `ReviewView` serves both paths from one view — straight after generation and
  reopened from Products — with marketplace chips, per-asset pass/warn/fail
  badges, the violation wording from the rules engine, per-asset Copy and a
  `ShareLink` export.
- `ProductsView` now loads from the server and opens a listing on tap, falling
  back to the SwiftData mirror when offline and labelling it as such.
- A marketplace that produced nothing shows **fail**, and a failure banner names
  the reason, so a gap is never mistaken for a clean result.
- `StoredAssetDTO.compliance` degrades an unrecognised status to `warn` rather
  than failing to decode, so a status written by a newer build cannot hide a
  whole listing.

Validation: **127 iOS tests in 19 suites pass**, 68 API tests pass, typecheck
clean, all endpoints answer 200.

### A regression I introduced and fixed

`src/instrumentation.ts` used `NodeSDK`, which pulls in every OTLP exporter
including gRPC. Webpack could not resolve the Node built-ins those reach
(`stream`, then `fs`), and **the whole API went down — every route 404 then 500**,
not just tracing. Unit tests did not catch it because it only appears when
Next.js bundles.

Fixed by using `NodeTracerProvider` from `@opentelemetry/sdk-trace-node`
(Langfuse's span processor exports over HTTP by itself, so the full SDK was never
needed) plus `serverExternalPackages` in `next.config.ts`. `@opentelemetry/sdk-node`
is uninstalled. Verified by checking every endpoint returns 200 and the dev log
contains zero module-resolution errors.

Worth carrying forward: **a green unit suite says nothing about whether the app
boots.** Hit a real endpoint after touching anything the bundler sees.


## Claude — findings 3/7/8 (2026-09-14)

Validation: **131 iOS tests in 19 suites pass**, **86 API tests pass**, typecheck
clean, Debug build clean.

### 🔴 Account deletion is broken, and the cause is a migration that was never written

`account-deletion.ts` calls `db.rpc("begin_account_deletion")`. That function
exists **nowhere** — no migration file in the repo, and `POST /rest/v1/rpc/
begin_account_deletion` returns 404 on the live project. Every deletion attempt
fails with 500 "Could not start account deletion".

Reproduced end to end: created an account with a product and a stored cutout,
called delete → **500**, and afterwards the photo was still in storage, the
product row still present, the workspace still named "My workspace", and the old
session still authorised (`GET /api/credits` → 200).

In-app deletion is mandatory for review (SPEC §5.3), so this blocks submission.

`api/supabase/migrations/0002_account_deletion.sql` is now written and reviewable.
It adds **no tables and no columns** — only a function that locks the account's
workspaces and tombstones the user using the existing `deleted_at`, so
`verifyAccount` rejects further requests while the slower cleanup runs. It is
idempotent, so a retried deletion records one deletion rather than two.

**It has NOT been applied.** SPEC §0 requires asking before a schema change;
deletion stays broken until the owner approves running it.

### [#3] Account isolation was half-landed and did not compile

`HEAD` did not build: `AppEnvironment` called `products.invalidate()`,
`generation.invalidate()` and `ProductStore(api:cacheDirectory:)`, none of which
existed. Seven compile errors, committed.

Implemented what the call sites required, rather than deleting them:
- `OfflineCache` — a per-account JSON cache inside the account's own directory,
  so one seller's listings cannot be read by the next person on the device.
  Every read is best-effort; SPEC §9 keeps the server as the source of truth.
- `invalidate()` on both stores: clears state **and** bumps the request token, so
  a response in flight for the previous account cannot land on the new one.
- `ProductStore` restores its list from disk at init and re-caches on write;
  `GenerationStore` serves a cached listing when the network fails, because work
  the seller paid for should still open offline.

### [#8] A new account now has credits

`ensureOrg` grants 100 credits once, at workspace creation — SPEC §6's own trial
figure, not an invented business model. Granting on every sign-in would be free
credits for anyone who signs out and back in.

Verified live: a brand-new account reports `{"balance":100}` with no manual
grant. The StoreKit purchase path remains M5.

### Two test defects fixed

- The e2e sign-in UI test probed `/api/health`, which never touches Supabase. A
  backend running without database credentials answered 200 and the test then
  **failed instead of skipping**. It now probes the sign-in route itself.
- `products.test.ts` used a 9-byte stub PNG. Validation was since tightened to
  require complete image data — correctly, since a truncated PNG passes a
  magic-number check and fails expensively later. The fixture is now a real
  2x2 RGBA PNG with correct CRCs.

### Still open from the readiness review

`[#1]` production URL, `[#4]` privacy/support URLs, `[#5]` AI consent is written
(`AIConsent.swift`) but **not wired to any screen**, `[#7]` Apple token
revocation, `[#11]` three AVFoundation Sendable warnings.


## Claude — manual cutout refinement (2026-09-15)

Closes the last open M3 item: "Add manual cutout refinement… there is no
refinement editor yet." Until now a low-confidence cutout only told the seller
to retake the photo, which SPEC §4.1 explicitly asks us not to settle for.

Validation: **159 iOS tests in 23 suites pass**, 91 API tests pass, Debug build
clean.

### What it does, and what it deliberately does not

- `RefinableMask` — the pixel arithmetic, with no image IO and no SwiftUI, so
  the logic that decides what gets uploaded is testable without a camera,
  without Vision and without a screen. 16 tests.
- `CutoutRefiner` — decode / preview / re-encode, and it **re-runs
  `CutoutAssessment` on the result**. A refined cutout is graded on merit, not
  accepted because a human touched it. 8 tests.
- `CutoutRefinementView` — erase brush with size control, "Harden edges", undo,
  a transparency checkerboard so erased areas do not read as white product on a
  white card.

**There is no restore brush.** `ProductCutout` stores only the masked PNG, and
`CaptureDraftStore` persists it; the pixels Vision removed are gone. A restore
control would be a button that silently does nothing, so the screen says plainly
that erased areas cannot be brought back.

### Two defects the tests caught in my own code

1. `CutoutRefiner` used `CGImageAlphaInfo.last` (straight alpha). CoreGraphics
   has **no 8-bit straight-alpha RGBA context** and rejects it, so every context
   creation returned nil — the editor would have failed to open at runtime. Now
   `premultipliedLast`.
2. That forced a second fix: in a premultiplied buffer, `hardenEdges` raising a
   pixel's alpha from 128 to 255 without scaling its colour back up leaves a
   half-lit pixel — a grey rim exactly where the halo was. It now
   un-premultiplies any pixel it promotes to opaque.

### StoreKit `.notEntitled` — independently reproduced

Confirmed the readiness review's finding on iOS 26.5 Simulator. Also tested one
hypothesis it did not cover: the StoreKit configuration was attached only to the
scheme's **Launch** action, not its Test action. Attaching it to the Test action
made no difference, and XcodeGen 2.46 does not emit `storeKitConfiguration`
under `test:` anyway, so that dead key was removed from `project.yml`.
The test already uses `SKTestSession`, which should not need the scheme at all.
The blocker stands: it needs a different runtime or a real device.


## Claude — paid credits no longer expire (2026-09-15)

The owner settled readiness item 1: **keep paid credits, let only feature access
end with the subscription.**

`api/supabase/migrations/0005_paid_credits_do_not_expire.sql`:

- `reconcile_credit_periods` sets `expires_at` only for `kind='trial'`. Plan
  grants keep `billing_period_end` — it still schedules the next month's grant —
  but it no longer ends the credits.
- Existing unexpired plan grants have `expires_at` cleared. Already-expired
  grants are left alone: reversing one would mint credits from a rule change
  rather than a payment, and there is no production data to restore.
- Top-ups were already unaffected; they never carried an expiry.
- Feature access needed no change. `billing.ts` derives the tier from the
  `subscriptions` table (`status='active'` and `expires_at > now`), never from
  the credit balance — the separation the decision depends on was already there.

SPEC §6's "credits expire at the end of each billing month" is replaced, and
`test-generation-db.py` updated: the annual case now expects 1100 and asserts
**zero** `subscription.expiry` rows, where it previously expected 300.

Verified by running the disposable-cluster test with all migrations applied —
10/10 pass, including "annual grants skip missed months; paid credits never
expire". 91 API tests, 159 iOS tests, typecheck clean.

**Migration 0005 is not applied to the live Supabase project.**

## Current slice

- `CaptureView` sends camera HEIF data and PhotosPicker imports through the same on-device Vision pipeline. Image orientation is applied before the centered square crop.
- Segmentation runs away from the main actor, with cancellation when capture disappears. The review sheet shows the transparent PNG or an actionable quality warning.
- Up to three usable cutouts are retained in memory. A rejected cutout or processing failure leaves room to retry a camera shot. Start over clears the series and releases hardware exposure / white-balance locks.
- Camera reopen reuses configured inputs and outputs. In-flight capture is guarded, and its delegate completes on the final capture callback. Flash selection is passed to supported hardware.
- Claude's second review identified interruption handling as the remaining capture risk. Session notifications now update camera availability, fail interrupted requests, and restore the preview after interruption. Cancellation and a 20-second timeout release an unfinished capture exactly once, with a visible camera retry action.
- Marketplace framing still uses the existing API-backed `RulesStore`. Rules loading and camera startup run concurrently.

## Product persistence — server side done (Claude Code)

`POST /api/products` and `GET /api/products` exist and were exercised against the
live Supabase project, not mocked.

- `src/lib/products.ts` keeps validation pure (`validateCreateProduct`) so it is
  testable without Supabase; the database and storage work sits behind it.
- The cutout must be a PNG. A JPEG or arbitrary base64 is rejected by checking the
  PNG signature — a JPEG would drop the alpha channel and the compositing step
  would paste a white box onto the generated background (SPEC §4.1/§8).
- Cutouts go to a **private** `cutouts` bucket at `{orgId}/{productId}.png`. The
  bucket is created on demand. Org-scoped paths are the access boundary.
- The product row is written before the image: a product with no image is
  recoverable, an orphaned image is not.
- Decoded cutouts are capped at 4 MB. TODO(M4): move to a signed
  direct-to-storage upload so the image never travels through the API.
- No schema change was needed — `products.attributes` holds `keyFeatures`.

Verified live: 201 with a real product id, the row carries `cutout_url` and
`attributes`, the bucket is private, `GET` returns the product, and a request
with no token is 401.

## Remaining M3 work

M3 is **not complete**.

1. Add manual cutout refinement and let the seller review or replace individual angles. Current low-confidence results offer another photo; there is no refinement editor yet.
2. ~~iOS half of product creation~~ — **done, pending review.** `ProductDetailsView`
   (design step 2), `ProductStore`, `ProductModels`, and a Continue affordance in
   `CaptureView`. Only the *main* cutout is uploaded; see the review notes.
3. ✅ **Text generation — composed and verified end to end with real Claude calls.**

   `POST /api/products/:id/generate` runs: load product → check balance →
   vision on the stored cutout → listing copy per marketplace → ad scripts →
   validate every generated asset with the **M2 rules engine** → write `assets`
   and `generations` rows → charge per unit that succeeded.
   `GET` on the same path quotes the credit cost before the seller commits
   (design step 3).

   Live run, Amazon + TikTok Shop + 1 script:
   - 6 credits charged, balance 400 → 394, no failures.
   - 5 asset rows, all `pass`, each judged by the same engine that judges a
     seller's own text — the model is not trusted to have obeyed the limits it
     was given.
   - 4 `generations` rows carrying real `actual_cost_usd` (total $0.0442) and
     `latency_ms`; `langfuse_trace_id` null because no keys are set.
   - Credit gate proven: with a 0 balance the request was refused **before any
     model ran**, so a refused request costs nothing (SPEC §6).
   - Ledger stayed append-only: `-2 generation.script`, `-2 generation.title`,
     `-2 generation.title`, `+400 subscription.grant`.

   `src/instrumentation.ts` now starts the OTel exporter when Langfuse keys
   exist, and logs that calls run untraced when they do not.

   iOS side built too: `GenerationModels`, `GenerationStore`, and
   `MarketplacesView` (design step 3) — marketplace rows, tier badges, ad-script
   stepper, live credit quote, "Generate listing". `GET /api/credits` returns the
   balance for the footer. Capture → Product details → Marketplaces now runs as
   one flow. `scriptCount` is capped at 10 server-side.

   Still open: the Review screen (design step 4) and the cutout refinement
   editor.

Providers are settled: Claude for vision and ad scripts, Kling for backgrounds
only, Langfuse for tracing. `src/lib/ai/types.ts` holds the protocol and
`src/lib/ai/pricing.ts` computes real cost — an unpriced model returns null, never
zero. `ANTHROPIC_SCRIPT_MODEL` defaults to `claude-sonnet-5` because SPEC §6
prices an ad script at 2 credits (~$0.04) and Opus 5 output alone exceeds that.

Keep marketplace limits on the server. Read `SPEC.md` before continuing; ask before changing the database schema or choosing an image-generation provider. Do not start M4 yet. Never read or copy `.env` secrets into prompts or handoff notes.

## Device verification still required

Simulator launch and pure-logic tests cannot establish real-camera behavior or Vision foreground inference quality. On an iPhone, check camera permission denial/recovery, tab switching, repeated shutter taps, flash, portrait orientation, exposure lock/reset, library import, and rejection/retry for difficult subjects.

Also interrupt a pending shot with a phone call or backgrounding, then return and retry. Notification handling follows [Apple's capture-session state APIs](https://developer.apple.com/documentation/AVFoundation/AVCaptureSession/runtimeErrorNotification).

The existing SwiftData cache is not the source of truth. Do not treat these temporary cutouts as saved products.

## Validation

- API: `npm run typecheck` clean and `npm test` passed, 59 tests (48 + 11 for product validation).
- `POST /api/products` exercised against live Supabase: 201, private `cutouts`
  bucket created, row carries `cutout_url` and `attributes`, `GET` returns it,
  no token is 401.
- iOS: 105 tests in 16 suites pass on iPhone 17 / iOS 26.5 Simulator, with the Vision segmentation suite skipped (no inference context in the simulator).
- The selected iOS run included `ListingForgeTests` and the app launch UI smoke test. The live email sign-in UI test was not selected because it exercises the backend and can send email.
- Vision foreground inference and actual camera behavior still need a physical iPhone; a successful simulator build is not evidence of successful product segmentation.

### Flakiness — diagnosed and fixed

The intermittent `make test` failure was the live email sign-in UI test, and the
cause turned out to be two races in the test itself, not the backend:

1. `email.tap()` is asynchronous, so `typeText` sometimes ran before focus
   landed — "Neither element nor any descendant has keyboard focus". The test
   now waits for focus (reading `hasKeyboardFocus` by key, so it works with a
   hardware keyboard attached where `app.keyboards` never appears) and retries
   the tap once.
2. `submit.isEnabled` was read immediately after typing, but SwiftUI re-renders
   a frame or two after the binding changes. The test now waits for the field to
   report the typed value and for the button to enable.

Three consecutive full runs pass, and the test dropped from a 25 s timeout to
~6 s.

### Note on the build

`ios/project.yml` no longer lists `../api/.env.example` under `fileGroups`.
xcodegen hard-fails on a missing fileGroup path, and that file was deleted three
times, each time breaking every `make build/test/run`. The file is still in the
repo; the Xcode project just no longer depends on it existing.

## Review requested — iOS product creation (Claude Code → Codex)

New/changed: `Features/Capture/ProductDetailsView.swift`,
`Features/Products/ProductStore.swift`, `Networking/ProductModels.swift`,
`App/AppEnvironment.swift`, and the Continue affordance in `CaptureView.swift`.

Known weak points, worth more attention than the parts that are fine:

1. **Only the main cutout is uploaded.** The series captures up to three angles;
   `ProductDetailsView` sends `cutouts.first` and the rest are dropped when the
   sheet closes. The `assets` table already models per-angle images. This is the
   most consequential gap.
2. **Navigation is still tab + sheet, not the 4-step wizard** the design shows.
   The header says "2 of 4" while the app has no step 1 chrome around it.
3. **SwiftData mirroring runs in the view** after a successful create, and a
   failed `modelContext.save()` is swallowed — deliberate (the product exists on
   the server either way) but worth a second opinion on placement.
4. **Key features split on commas**, so a feature legitimately containing a comma
   is silently cut in two.
5. **No retry after a failed create.** The cutout stays in memory, but killing
   the app loses it. There is no draft persistence.
6. **Base64 in a JSON body** with a 4 MB decoded cap. A real 1600px cutout may
   come close; signed direct-to-storage upload is the intended fix (M4).

Verified rather than assumed: Supabase returns microsecond-precision timestamps
(`2026-09-13T06:18:36.674469+00:00`) and `ISO8601DateFormatter` with
`.withFractionalSeconds` parses them. `ProductCacheMapperTests` pins that,
because falling back to `.now` would misdate every cached product silently.

## Notes for whoever picks up text generation

- **`npm i langfuse` installs the wrong thing.** That package is stuck at v3 and
  uses the batch ingestion API Langfuse Cloud removes on 2026-11-16. The current
  packages are `@langfuse/tracing@5`, `@langfuse/otel@5`, `@opentelemetry/sdk-node`.
- **The env var is `LANGFUSE_BASE_URL`, not `LANGFUSE_HOST`.** The v5 SDK ignores
  the latter, so a self-hosted instance would have been silently bypassed and
  traces shipped to the default cloud host. Fixed in `env.ts`, `.env.example` and
  `.env`.
- **Node's test runner rejects TypeScript parameter properties**
  (`constructor(readonly x: T)`). Next.js compiles them; `node --test` strips
  types only and throws `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX`. `ProviderError` is
  written out longhand for this reason — don't "tidy" it back.
- **`ModelUsage.costUSD` is `number | null` on purpose.** An unknown model rate
  must stay null all the way to `generations.actual_cost_usd`. Collapsing it to 0
  reads as a free call and corrupts the margin numbers SPEC §9 exists to protect.
- **`balanceOf` reads every ledger row and sums them**, then cross-checks the
  newest `balance_after`. Summing is what "balance is derived" means; the column
  is an audit aid. Concurrent appends can race on that column — the sum stays
  correct. Serialise in a Postgres function when billing goes live (M5).

## Cost note worth carrying forward

The live run cost **$0.0442** against **$0.12** of credits (6 @ $0.02), but every
call ran on `claude-opus-5`: the repo `.env` still carried
`ANTHROPIC_SCRIPT_MODEL=claude-opus-5`, copied from an older `.env.example`,
which silently overrode the owner's decision to use Sonnet 5 for scripts. Now
corrected to `claude-sonnet-5`; the same work should land near **$0.018**.

Vision deliberately stays on `claude-opus-5` — reading a label wrongly produces a
false claim in a live listing, which is worth more than the token difference.

Two things this argues for: quote cost from `pricing.ts` before shipping a model
change, and treat the `generations` table as the place the answer actually lives.

## Codex review returned — product creation

See [CODEX_REVIEW.md](CODEX_REVIEW.md) for the review requested above: five P1
findings, five P2 findings, reproduction evidence, and the exact validation scope.
Prioritize account-scoped cache, preservation of every captured angle, safe retry
after partial creation, stale save callbacks, and storage cleanup on account
deletion. The existing manual retry button works; idempotency and durable drafts
are the missing pieces. This review does not sign off the generation/credits
code being added concurrently. No implementation fixes or commits were made by
Codex in this review pass.

## Bug found by a test, worth knowing about

`APIClient` built every URL with `baseURL.appendingPathComponent(path)`, which
percent-encodes `?` **into the path**. The moment a caller needed a query string
(the credit quote), the app requested a literal segment named
`generate%3Fmarketplaces=...` and the server answered 404 — a wrong URL, not an
obvious error.

The fix uses `URLComponents`, with one trap worth recording: a `URLComponents`
that has a host but a path not starting with `/` is invalid and `.url` returns
**nil silently**. The first fix therefore appeared to work — the fallback
produced the right path — while quietly dropping the query. `APIClientURLTests`
pins both the path and the query now.

## Codex implementation update — 14 September 2026

The earlier review-only notes above are historical. See [SUBMISSION_READINESS.md](SUBMISSION_READINESS.md) for current changes, validation and remaining submission blockers. Generation and billing migrations were explicitly approved for **local implementation and testing only**. No production migration or App Store upload has occurred.

Do not restore the old account-creation 100-credit grant: trial credits now come from verified Apple introductory offers. Do not finish a StoreKit transaction before server acknowledgment, or accept unsigned Xcode JWS payloads on the real backend. The ledger is append-only and generation output/debit are atomic. All captured angles now upload with resumable draft identity; cutouts and uncertain generation IDs survive relaunch.

Pending owner decision: paid credit expiry conflicts with current Apple §3.1.1 wording. The proposal is to preserve purchased credits, with subscription feature access still expiring normally. Current migration retains SPEC expiry pending that answer. Real production policy/support/API/terms URLs and Apple Sandbox/Release validation are still required.

## Codex — recover missed paid periods (2026-09-15)

Migration 0006 fixes a remaining 0005 bug: paid annual months were silently
skipped if reconciliation occurred after their period ended. Every started paid
period is now delivered exactly once, even after subscription expiration.
Expired free trials and revoked purchases remain excluded; future periods stay
scheduled. Feature access still comes from the subscription, not credit balance.

Regression reproduced before the fix. All 10 local PostgreSQL groups, 91 API
tests and typecheck pass. No production migration applied. StoreKit still needs
a working alternate runtime or an available physical device, plus real Apple
Sandbox validation. Production URLs remain missing.
