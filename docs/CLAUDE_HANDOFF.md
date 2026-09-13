# ListingForge development handoff

Updated 2026-09-13 after a Codex / Claude Code review of the ongoing M3 capture work.

## Current slice

- `CaptureView` sends camera HEIF data and PhotosPicker imports through the same on-device Vision pipeline. Image orientation is applied before the centered square crop.
- Segmentation runs away from the main actor, with cancellation when capture disappears. The review sheet shows the transparent PNG or an actionable quality warning.
- Up to three usable cutouts are retained in memory. A rejected cutout or processing failure leaves room to retry a camera shot. Start over clears the series and releases hardware exposure / white-balance locks.
- Camera reopen reuses configured inputs and outputs. In-flight capture is guarded, and its delegate completes on the final capture callback. Flash selection is passed to supported hardware.
- Claude's second review identified interruption handling as the remaining capture risk. Session notifications now update camera availability, fail interrupted requests, and restore the preview after interruption. Cancellation and a 20-second timeout release an unfinished capture exactly once, with a visible camera retry action.
- Marketplace framing still uses the existing API-backed `RulesStore`. Rules loading and camera startup run concurrently.

## Remaining M3 work

The capture-to-cutout feedback slice is implemented; M3 is **not complete**.

1. Add manual cutout refinement and let the seller review or replace individual angles. Current low-confidence results offer another photo; there is no refinement editor yet.
2. Move capture into the product-creation flow, add name/category, upload the cutout PNG, and persist the server-created product. Current PNGs are session-only and are not uploaded or saved as products.
3. Add marketplace selection and text generation with the Anthropic Messages API, Langfuse tracing, measured cost, and the append-only credit ledger required by `SPEC.md`.

Keep marketplace limits on the server. Read `SPEC.md` before continuing; ask before changing the database schema or choosing an image-generation provider. Do not start M4 yet. Never read or copy `.env` secrets into prompts or handoff notes.

## Device verification still required

Simulator launch and pure-logic tests cannot establish real-camera behavior or Vision foreground inference quality. On an iPhone, check camera permission denial/recovery, tab switching, repeated shutter taps, flash, portrait orientation, exposure lock/reset, library import, and rejection/retry for difficult subjects.

Also interrupt a pending shot with a phone call or backgrounding, then return and retry. Notification handling follows [Apple's capture-session state APIs](https://developer.apple.com/documentation/AVFoundation/AVCaptureSession/runtimeErrorNotification).

The existing SwiftData cache is not the source of truth. Do not treat these temporary cutouts as saved products.

## Validation

- API: `npm run typecheck` and `npm test` passed, 48 tests.
- iOS: build and test on iPhone 17 / iOS 26.5 Simulator passed, 92 test cases passed and one Vision segmentation case skipped. Parameterized tests produced 96 successful executions.
- The selected iOS run included `ListingForgeTests` and the app launch UI smoke test. The live email sign-in UI test was not selected because it exercises the backend and can send email.
- Vision foreground inference and actual camera behavior still need a physical iPhone; a successful simulator build is not evidence of successful product segmentation.
