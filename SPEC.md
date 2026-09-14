# Build Spec — Multi-Marketplace Listing Generator (Swift / iOS)

> Save as `SPEC.md` in the repo root and tell Claude Code:
> "Read SPEC.md and start with Milestone 1."

---

## 0. How I want you to work

- Read this whole spec before writing any code.
- **Ask me before**: adding a Swift package not listed here, changing the DB
  schema after Milestone 2, or picking an image generation provider. Do not ask
  permission for routine implementation choices.
- Build in milestone order. Stop at the end of each one, show me what works, and
  wait. Do not skip ahead.
- **You must build and run the app yourself before telling me a milestone is
  done** — see §1 for the commands. Do not hand me code you have not compiled.
- Write tests only for: credit accounting, compliance rules, and cost
  calculation. Skip tests elsewhere for now.
- Commit after each working feature with a clear message.
- If something here is ambiguous or looks wrong, say so before building it.

---

## 1. Your build loop

Run these yourself. Do not ask me to copy errors out of Xcode.

```bash
# Build (fail fast, readable output)
xcodebuild -scheme ListingForge \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet build 2>&1 | tail -50

# Test
xcodebuild -scheme ListingForge \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test 2>&1 | tail -50

# Run
xcrun simctl boot "iPhone 16" 2>/dev/null; \
xcrun simctl launch booted com.ctt.listingforge
```

Project files are generated with **XcodeGen** from `project.yml` — never edit
`.xcodeproj` directly, it makes diffs unreadable. Regenerate with `xcodegen`
after adding files.

I will open Xcode for previews, Instruments, and StoreKit testing. You work in
the terminal.

---

## 2. What we're building

A **native iOS app** for e-commerce sellers. The seller photographs a product
and gets back a **complete, marketplace-compliant listing package**:

- Product images sized and rule-checked per marketplace
- Product title + description in each marketplace's required format
- Short-form video ad scripts (TikTok-style hooks)

**Primary market:** US TikTok Shop sellers. Secondary: the same sellers listing
on Amazon, eBay, Etsy.

**The value is NOT image generation.** That's a commodity. The value is: *output
is guaranteed to pass each marketplace's listing rules, and adapting an asset
from one marketplace to another is one tap.* The rules engine is the most
important code in this project. Give it the most care.

### Non-goals for v1

No order management, inventory sync, analytics dashboards, team seats, iPad
layout, Android, AI video generation, or marketplace API write-back. Refuse
scope creep toward these.

---

## 3. Stack

| Layer | Choice |
|---|---|
| Min target | **iOS 17.0** (required for Vision subject lifting) |
| UI | SwiftUI, `@Observable` (Observation framework), no ViewModels-as-ObservableObject |
| Concurrency | Swift Concurrency throughout. No completion handlers, no Combine. |
| Camera | AVFoundation — custom capture session, not `UIImagePickerController` |
| On-device vision | Vision framework |
| Local persistence | SwiftData (offline cache of products + assets) |
| Networking | `URLSession` + `async/await`, thin typed client. No Alamofire. |
| Auth | Sign in with Apple + email. **No Google login in v1.** |
| Payments | **StoreKit 2**, direct. No RevenueCat. |
| Push | APNs via the backend |
| Backend | Next.js 15 API routes on Vercel — API only, no web UI |
| DB | Postgres via Supabase |
| Jobs | Inngest |
| Storage | Supabase Storage |
| Text generation | Anthropic Messages API |
| Image generation | **Ask me before choosing.** Behind a protocol. |
| Observability | Langfuse on all model calls |

Keep third-party Swift packages near zero. The only ones I expect: none. If you
think you need one, ask first.

**Repo layout:** `/ios` (Xcode project) and `/api` (Next.js) in one repo.

---

## 4. Use the platform (this is why we chose Swift)

### 4.1 On-device subject segmentation — mandatory

Use Vision's `VNGenerateForegroundInstanceMaskRequest` (iOS 17+) to cut the
product from its background **on the device**, before anything is uploaded.

This is not an optimization. It is a core economic decision: segmentation
becomes free and instant instead of a paid server round-trip. Upload the cutout
PNG with alpha, not the original frame.

Fall back gracefully: if the mask is low-confidence (thin, transparent, or
reflective products), tell the user and offer manual refinement rather than
shipping a bad cutout.

### 4.2 Capture quality

Custom `AVCaptureSession` with:

- A framing overlay showing the safe area for a 1:1 main image at the required
  product fill ratio.
- **Locked exposure and white balance across a capture series**, so multiple
  angles of the same SKU match. Expose a "lock" affordance after the first shot.
- A lighting warning when the frame is under-lit or has a hard shadow edge.
- Capture in HEIF, convert server-side.

This is the difference between our source photos and a seller's camera-roll
dump. Do not degrade it to save time.

### 4.3 StoreKit 2

Use `Transaction.currentEntitlements` and `Transaction.updates` directly.
Requirements:

- A long-running `Transaction.updates` listener started at app launch, before
  any UI. Missing this loses purchases made outside the app.
- `.finish()` a transaction **only after** the backend confirms the credit grant.
- **Restore Purchases** button that actually works.
- `SubscriptionStoreView` for the paywall unless you have a reason not to.
- A `.storekit` configuration file so we can test purchases in the simulator
  without App Store Connect.

---

## 5. App Store constraints — treat as requirements

Verify current guideline text before submission; these change.

**5.1 Payments must be IAP.** No Stripe, PayPal, or external checkout in the
app. No pricing comparisons, no "cheaper on our website," no link to a web
purchase page anywhere in the binary.

> US link-outs currently carry no Apple commission after the Epic v. Apple
> rulings, but the Supreme Court agreed to hear the case in June 2026. That is a
> window, not a foundation. **v1 ships IAP-only.**

**5.2 Guideline 4.2, minimum functionality.** No WebViews in any core flow.
The native capabilities must be real: camera, Photos, share sheet, push, offline
cache. Given §4 this is satisfied by design — don't undermine it.

**5.3 Account deletion in-app is mandatory.** A real endpoint that deletes data,
not a mailto: link.

**5.4 Privacy nutrition labels.** Maintain an accurate inventory of collected
data as you build. Product photos are user content — declare them.

**5.5 AI content moderation.** A report button on every generated asset, and a
server-side safety check on prompts. Apps generating content get rejected
without this.

**5.6 Sign in with Apple** is required if any third-party login exists. We only
have Apple + email, so this is satisfied — keep it that way.

---

## 6. Credits and billing

**App Store Connect setup** — one subscription group, three levels, so upgrades
and downgrades are handled natively:

| Product ID | Type | Price |
|---|---|---|
| `starter_monthly` / `starter_annual` | Auto-renewable | $29.99 / $299.99 |
| `pro_monthly` / `pro_annual` | Auto-renewable | $79.99 / $799.99 |
| `scale_monthly` / `scale_annual` | Auto-renewable | $199.99 / $1,999.99 |
| `topup_300` | **Consumable** | $14.99 |

Enroll in the App Store Small Business Program: 15% commission instead of 30%
under $1M annual proceeds.

**Credit costs** — single source of truth in `config/credits.json`, served by
the API:

| Action | Credits |
|---|---|
| Title or description | 1 |
| Ad script | 2 |
| Image generation | 5 |
| Marketplace conversion (no re-render) | 0 |

1 credit ≈ $0.02 underlying cost. Conversion is deliberately free — it's the hook.

| Tier | Credits/mo | Marketplaces |
|---|---|---|
| Starter | 400 | TikTok Shop only |
| Pro | 1,100 | All four |
| Scale | 2,800 | All four + bulk |

**Rules to enforce:**

- **The server is the source of truth for entitlements.** Verify the signed
  `JWSTransaction` server-side against Apple's public keys and grant credits
  there. Never grant credits from a client claim — this is how these apps get drained.
- Implement **App Store Server Notifications V2** to catch renewals, refunds,
  cancellations, and billing retries. Without it, entitlement state silently rots.
- **Paid credits never expire** (owner decision, 2026-09-15). Apple Guideline
  3.1.1 does not allow purchased credits to expire, so both the monthly plan
  allowance and top-ups keep their value indefinitely. What ends with the
  subscription is **feature access**, decided from the `subscriptions` table,
  never from the credit balance. The free trial still expires — it was not
  purchased. Annual plans still grant monthly, not 13,200 at once; missed months
  do not accumulate.
- Top-up credits consumed only after plan credits are exhausted.
- Check balance **before** dispatching a generation, charge on success only.
  Failed generation refunds automatically.
- On a `REFUND` notification: reverse the granted credits, allow the balance to
  go negative, block generation until resolved.
- Tier gating: a Starter user tapping Amazon sees the paywall sheet, not an error.
- 7-day free trial with 100 credits, configured as an introductory offer.

---

## 7. The rules engine

Each marketplace has a declarative rule set. **Rules live in versioned JSON
served by the API and cached on device** — I must be able to update them without
an App Store review. This is the single biggest reason not to hardcode them.

```jsonc
{
  "id": "amazon",
  "version": "2026-09",
  "displayName": "Amazon",
  "images": {
    "main": {
      "aspectRatio": "1:1",
      "minLongestEdge": 1600,
      "background": { "mustBePureWhite": true, "rgb": [255, 255, 255] },
      "productFillRatio": { "min": 0.85 },
      "forbid": ["text", "logo", "watermark", "border", "additionalProps"]
    },
    "secondary": { /* looser */ }
  },
  "title":       { "maxChars": 200, "forbid": ["allCaps", "promoLanguage"] },
  "description": { "format": "bullets", "maxBullets": 5, "maxCharsPerBullet": 500 }
}
```

v1 marketplaces: `tiktok_shop`, `amazon`, `ebay`, `etsy`.

I will supply the real current specs. **Do not invent limits from memory** —
scaffold with `"TODO_VERIFY": true` on any value you aren't certain of, and list
those TODOs at the end of the milestone.

### The two functions that matter

```swift
// Every violation, not just the first.
func validate(_ asset: Asset, against rules: MarketplaceRules) -> [Violation]

// Adapt an asset from marketplace A to B. Report what it did AND what it
// could not fix automatically.
func convert(_ asset: Asset, from: MarketplaceRules, to: MarketplaceRules) -> ConversionResult
```

`convert` is what people pay for. The canonical case: a lifestyle image that
works as a TikTok Shop main image contains overlay text and a human hand — both
forbidden on an Amazon main image. Detect it, explain it in plain English, offer
the fix (re-render on white, or demote to a secondary slot).

**Never silently "fix" by degrading. Always report.**

Implement this **on the server**, not in Swift — the app displays results. Same
logic must serve a future Android app and the bulk API.

---

## 8. Label fidelity — hard quality bar

Generative models alter packaging text and logos. That gets sellers reported and
delisted.

1. Segment on device (§4.1).
2. Generate or select **background/scene only**.
3. Composite the **original, unmodified product pixels** onto it.

Never ship an image where packaging text was regenerated. If an edit can't be
done without touching the product surface, refuse it in the UI and say why.

---

## 9. Data model

```
users            -> id, apple_user_id, email, deleted_at
organizations    -> id, owner_user_id, name
products         -> id, org_id, name, category, source_photo_url,
                    cutout_url, attributes jsonb
assets           -> id, product_id, type(image|title|description|script),
                    marketplace, content/url, derived_from_asset_id,
                    validation_status, violations jsonb
generations      -> id, org_id, asset_id, provider, model, credits_charged,
                    actual_cost_usd, latency_ms, langfuse_trace_id
credit_ledger    -> id, org_id, delta, reason, balance_after,
                    original_transaction_id, created_at
subscriptions    -> org_id, product_id, tier, status, expires_at,
                    original_transaction_id, credits_per_month
```

`credit_ledger` is **append-only**. Never UPDATE. Balance is derived. Apple
refund disputes make this non-optional.

Always write `actual_cost_usd` — I need real margin numbers, not estimates.

Store `original_transaction_id` on every grant so a refund notification can find
exactly what to reverse.

Mirror `products` and `assets` into SwiftData for offline viewing. SwiftData is
a cache, never the source of truth — the server wins on every conflict.

---

## 10. User flow

1. **Capture** — guided camera (§4.2), on-device cutout (§4.1) shown immediately
   as instant feedback. Library import as a secondary path.
2. **Describe** — name + category. One screen. Keep it short.
3. **Marketplaces** — tier-gated, native paywall sheet when locked.
4. **Generate** — job dispatched; the app may background. **Push notification on
   completion.** Generation takes 10–30s. Never block the UI, never require
   foreground.
5. **Review** — compliance badge per asset: pass / warn / fail, with the rule
   named in plain English. Tap a violation for the fix.
6. **Convert** — one tap to adapt to another marketplace, showing what changed
   and what needs manual attention.
7. **Export** — share sheet, save to Photos, copy text. Files named per
   marketplace convention.

Recent products and assets must be viewable offline.

---

## 11. Milestones

**M1 — Foundation.** XcodeGen project, SwiftUI shell, Sign in with Apple, API
skeleton, Supabase schema, account deletion. Builds and runs on the simulator.
No features.

**M2 — Rules engine.** Config for all four marketplaces (with TODO_VERIFY).
`validate` and `convert` on the server, unit-tested against fixtures. No UI —
prove it with tests.

**M3 — Capture + text.** AVFoundation capture, Vision cutout, product creation,
titles/descriptions/scripts per marketplace. Credit ledger live. Langfuse on.
First genuinely usable build.

**M4 — Images.** Provider protocol, composite pipeline, Inngest jobs, APNs,
validation wired to the rules engine.

**M5 — Billing.** StoreKit 2, products, `.storekit` test config, server-side
JWS verification, Server Notifications V2, tier gating, trial, top-ups, monthly
reset, refunds, restore.

**M6 — Submission.** Share export, offline cache, content reporting, privacy
labels, empty/error states, screenshots, review notes with a working demo account.

Ship M1–M3 before touching M4+.

---

## 12. Things I will be annoyed by

- Code handed to me that you did not compile.
- Entitlements trusted from the client instead of verified server-side.
- `.finish()` called before the backend confirms the grant.
- No `Transaction.updates` listener at launch.
- Credits mutated with UPDATE instead of appended to the ledger.
- Credits charged for a failed generation.
- Marketplace limits hardcoded instead of served as config.
- Rules engine logic duplicated in Swift.
- Server-side segmentation when Vision can do it on device.
- Generated images where packaging text was re-rendered.
- Blocking the UI while an image generates.
- Combine, completion handlers, or `ObservableObject` in new code.
- Editing `.xcodeproj` directly instead of `project.yml`.
- A "quick prototype" version of any of the above that we'll "clean up later."

Start with Milestone 1. Tell me your plan before writing code.
