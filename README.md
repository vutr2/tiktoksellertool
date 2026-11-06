# Listing Force

A native iOS app for e-commerce sellers. Photograph a product once and get a
listing package that follows each marketplace's rules: product images, a title
and description in each marketplace's format, and short-form video ad scripts.

Built for US **TikTok Shop** sellers who also list on **Amazon**, **eBay** and
**Etsy**.

> The codebase and Xcode project are named **ListingForge**. **Listing Force**
> is the name customers see in the App Store.

## Why it exists

Image generation is a commodity. What this app adds:

- **Every output is checked against the marketplace's listing rules.** Each
  asset gets a pass, warn or fail badge, and each problem is explained in plain
  language.
- **Converting an asset from one marketplace to another takes one tap.** The
  app shows what it fixed and what still needs the seller's attention. It never
  "fixes" something silently by degrading it.
- **The product itself is never redrawn.** The cutout happens on the device, a
  model generates only the background, and the original product pixels are
  composited on top, so packaging text and logos stay untouched.

## Features

- **Guided capture.** A custom AVFoundation camera with a framing overlay,
  exposure and white balance locked across a series of shots, and lighting
  warnings.
- **On-device cutout.** Vision (`VNGenerateForegroundInstanceMaskRequest`)
  removes the background before anything is uploaded. When the mask is weak,
  the seller can refine it by hand.
- **Listing copy.** Claude reads the product photo and writes titles and
  descriptions for each marketplace. Industry packs steer the tone and catch
  claims the seller is not allowed to make.
- **Video ad scripts.** TikTok-style hooks laid out as a timeline.
- **Studio shots.** Scene presets for each industry (beauty, fashion, home,
  baby & kids, accessories).
- **Rules engine.** Rules for each marketplace live in versioned JSON served by
  the API, so they can change without an App Store review. `validate` returns
  every violation, not just the first one; `convert` reports what changed and
  what is left unresolved.
- **Credits and subscriptions.** StoreKit 2 with server-side JWS verification,
  App Store Server Notifications V2, an append-only credit ledger, and refunds
  that reverse credits.
- **Product library.** Products and assets are cached for offline viewing, and
  products can be hidden, shown and deleted, one at a time or in bulk.
- **English and Vietnamese.** The app interface, the server's messages and the
  generated copy all follow the seller's chosen language.
- **App Store requirements.** In-app account deletion, consent before photos are
  shared with AI, a report button on generated content, and a privacy manifest.

## Tech stack

| Layer | Choice |
|---|---|
| iOS | Swift, SwiftUI with `@Observable`, Swift Concurrency, iOS 17+ |
| Camera and vision | AVFoundation, Vision (on device) |
| Local cache | SwiftData |
| Payments | StoreKit 2 (no RevenueCat) |
| Auth | Sign in with Apple, email one-time code |
| Backend | Next.js 15 API routes (API only), deployed on Vercel |
| Database and storage | Supabase (Postgres + Storage) |
| Text and vision AI | Anthropic Claude |
| Image AI | Kling (backgrounds only) or xAI Grok Imagine for Studio |
| Tracing | Langfuse on every model call |

The iOS app uses **no third-party Swift packages**.

## Repository layout

```
.
├── ios/                    # iOS app
│   ├── project.yml         # XcodeGen spec (the .xcodeproj is generated, not committed)
│   ├── ListingForge/       # App sources: Auth, Features/, Networking, Models, Support
│   ├── ListingForgeTests/  # Unit tests (Swift Testing)
│   ├── ListingForgeUITests/
│   ├── StoreKit/           # .storekit config for testing purchases in the simulator
│   └── scripts/            # Localization check, release validation
├── api/                    # Next.js backend
│   ├── src/app/api/        # API routes
│   ├── src/lib/rules/      # Rules engine + marketplace configs (JSON)
│   ├── src/lib/ai/         # Claude, Kling/xAI, pricing, tracing
│   ├── config/credits.json # Credit costs and plan allowances
│   ├── supabase/migrations/
│   └── tests/
├── docs/                   # Design proposals, reviews, submission checklist
├── scripts/                # Repo-wide helper scripts
├── Makefile                # Build, test and run from the terminal
└── SPEC.md                 # Product and engineering spec
```

## Getting started

### Requirements

- macOS with Xcode 26 and an iOS 17+ simulator
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Node.js 22.18 or newer (tests run TypeScript directly through `node --test`)
- A Supabase project
- API keys for Anthropic, Kling and Langfuse (xAI is optional)

### 1. Backend

```bash
cd api
npm install
# Create api/.env with the variables listed below
npm run dev          # http://localhost:3000
```

Apply the migrations in `api/supabase/migrations/` to your Supabase project, in
order (`supabase db push`, or paste each file into the SQL editor).

<details>
<summary><strong>Environment variables</strong></summary>

| Variable | Purpose |
|---|---|
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | Database and storage. The service role key bypasses RLS, so keep it on the server. |
| `SESSION_SECRET` | Signs session JWTs. Use a long random string. |
| `APPLE_AUDIENCE` | The iOS bundle ID, used to verify Sign in with Apple. |
| `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` | Apple key for revoking tokens on account deletion. The `.p8` content can use literal `\n`. |
| `EMAIL_FROM`, `RESEND_API_KEY` | Sends email sign-in codes. Without `RESEND_API_KEY`, the code is printed to the console (for development). |
| `ANTHROPIC_API_KEY` | Claude. Required for listing copy and scripts. |
| `ANTHROPIC_VISION_MODEL`, `ANTHROPIC_SCRIPT_MODEL` | Optional model overrides. |
| `KLING_API_KEY`, `KLING_BASE_URL` | Background generation. |
| `KLING_IMAGE_MODEL`, `KLING_COST_USD_PER_IMAGE` | Optional. Without a price, the cost is recorded as unknown instead of guessed. |
| `XAI_API_KEY`, `XAI_IMAGE_MODEL`, `XAI_BASE_URL` | Optional. Studio uses Grok Imagine when set, otherwise Kling plus compositing. |
| `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, `LANGFUSE_BASE_URL` | Tracing. Optional in development. |
| `APP_STORE_ENVIRONMENT`, `APP_STORE_APP_ID`, `APP_STORE_ALLOW_SANDBOX` | StoreKit transaction verification. |
| `REVIEW_ACCOUNT_EMAIL`, `REVIEW_ACCOUNT_CODE` | Optional. A fixed sign-in code for the App Review demo account only. |

</details>

### 2. iOS app

All iOS commands run from the repository root through the `Makefile`. Each one
runs `xcodegen` first, so a `.swift` file created outside Xcode is picked up.

```bash
make build    # regenerate the project and compile for the simulator
make test     # unit tests + UI tests
make run      # build, boot the simulator, install and launch
make i18n     # check every user-facing string has a Vietnamese translation
make devices  # list available simulators
```

The default simulator is `iPhone 17`. To use a different one:
`make run DEVICE='iPhone 17 Pro'`.

The app calls the production backend by default (`API_BASE_URL` in
`ios/project.yml`). To use a local backend, override `API_BASE_URL` when you
build.

> **Note:** the Vision cutout does not run in the simulator ("Could not create
> inference context"). Use a physical iPhone to test capture.

#### Demo mode

Debug builds can show sample data without a backend, camera or sign-in, which is
useful for screenshots:

```
--demo --screen products|review|paywall|settings|capture|details|marketplaces|studio|convert
```

Demo mode is compiled only into Debug builds and never reaches a Release
archive.

## Testing

```bash
npm --prefix api run typecheck
npm --prefix api test                          # rules engine, credits, billing, i18n, AI cost safety
python3 api/scripts/test-generation-db.py      # migrations + credit ledger against a throwaway Postgres
python3 -m unittest discover -s ios/scripts -p 'test_*.py'
make test
```

`test-generation-db.py` creates its own disposable PostgreSQL cluster. It never
reads `.env` or connects to an existing database.

## API overview

| Area | Routes |
|---|---|
| Auth | `POST /api/auth/apple`, `POST /api/auth/email/request-code`, `POST /api/auth/email/verify` |
| Account | `POST /api/account/delete` |
| Products | `GET/POST /api/products`, `PATCH/DELETE /api/products/:id`, `PUT /api/products/:id/cutouts/:index`, `POST /api/products/:id/complete`, `GET /api/products/:id/thumbnail` |
| Generation | `GET/POST /api/products/:id/generate`, `GET/POST /api/products/:id/scripts`, `GET/POST /api/products/:id/studio`, `GET /api/products/:id/assets` |
| Moderation | `POST /api/products/:id/report` |
| Rules | `GET /api/rules`, `POST /api/rules/validate`, `POST /api/rules/convert` |
| Billing | `GET /api/credits`, `GET/POST /api/billing`, `POST /api/billing/notifications` (App Store Server Notifications V2) |
| Health | `GET /api/health` |

Authenticated routes expect `Authorization: Bearer <token>`. Errors always use
the shape `{ "error": "message" }`.

## Credits

Credit costs and plan allowances live in
[`api/config/credits.json`](api/config/credits.json), and the API serves them
to the app.

| Action | Credits |
|---|---|
| Title or description | 1 |
| Ad script | 2 |
| Image generation | 5 |
| Marketplace conversion (no re-render) | 0 |

| Plan | Credits / month | Marketplaces |
|---|---|---|
| Starter | 400 | TikTok Shop |
| Pro | 1,100 | All four |
| Scale | 2,800 | All four |

The server is the only source of truth for credits. The ledger is append-only,
a failed generation is never charged, and paid credits never expire.

## Status

The app is in development and being prepared for its first App Store
submission. Not built yet:

- Background generation jobs (Inngest) and push notifications when a generation
  finishes
- Bulk workflows for the Scale plan
- Verified rule values for TikTok Shop, eBay and Etsy. Values that are not yet
  confirmed are marked `TODO_VERIFY`; run `npm --prefix api run rules:todos`
  for the list.

See [`docs/SUBMISSION_READINESS.md`](docs/SUBMISSION_READINESS.md) for the
current submission checklist.

## Documentation

- [`SPEC.md`](SPEC.md): product and engineering spec
- [`docs/SUBMISSION_READINESS.md`](docs/SUBMISSION_READINESS.md): App Store readiness
- [`docs/ACCOUNT_DELETION.md`](docs/ACCOUNT_DELETION.md): what gets deleted and what is kept
- [`docs/PRODUCT_LIBRARY.md`](docs/PRODUCT_LIBRARY.md): product library behavior
- [`docs/LOCALIZATION_REVIEW.md`](docs/LOCALIZATION_REVIEW.md): Vietnamese localization review
- [`docs/UI_REFRESH.md`](docs/UI_REFRESH.md): UI changes and intentional limitations
- [`api/README.md`](api/README.md): backend notes
