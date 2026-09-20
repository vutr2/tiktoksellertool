# Studio Shot: durable image tasks

Status: proposed; awaiting owner approval under SPEC §0. This document does
not change any database. Scope of approval requested: migration and local
tests only, not deployment or paid requests to Kling.

## Failure in the current flow

The Studio POST starts a Kling task, polls for up to 170 seconds, downloads
the image, saves it, then debits credits. A batch repeats this for each of
1/3/5 images within one Vercel request. iOS and the hosting platform can end
that request first. The task ID is held only in memory, so a retry can pay
Kling for another task. Saving an asset and charging credits are also separate
operations. This path does not call Langfuse.

## Proposed storage and transactions

Add a service-role-only `studio_jobs` table (RLS enabled), with:

- UUID, organization/product foreign keys with deletion cascade;
- industry, scene, variation index, immutable input hash, quoted credits/model;
- unique `(org_id, product_id, scene_id, variation_index)`;
- status: submitting, processing, completed, failed, or submission_unknown;
- provider task ID (unique when present), submission timestamp, last error,
  result path/asset ID, creation/completion timestamps;
- a reference to the existing `generation_requests` reservation and its lease.

Use the existing generation reservation pool so text and image requests cannot
reserve the same credits. New Postgres functions, restricted to service_role,
lock the organization and job consistently to:

1. Claim a variation and reserve credits before a single provider submission.
   An existing job returns its state instead of authorizing another submission.
   Existing successful Studio assets remain available without another debit.
2. Record the provider task ID. A lost create response or interrupted submission
   is marked `submission_unknown`; it is never blindly resubmitted. Confirmed
   provider rejections/failures release the reservation without charging.
3. Settle a completed image: insert the stored asset and usage, append exactly
   one debit, complete the reservation and job in one transaction. Duplicate
   polling/settlement returns the same result. A stale/deleted account cannot
   settle. Unknown provider USD cost remains NULL.
4. Keep Studio reservations valid for a bounded recovery window (24 hours).
   After expiry, re-check available credits under the same lock before saving
   and charging a late result; never overdraw or take another job's reservation.

No new provider, Swift package, background worker service, or APNs setup is
needed for this timeout fix. Server-side task storage is required; an in-memory
map or client-only task ID would lose work on Vercel restarts or lost responses.

## Request and app changes

- Version the Studio protocol. Each start call submits at most one image;
  a separate short request checks an existing task and saves a finished image.
  No request sleeps while waiting for image generation.
- Apply individual deadlines to provider submission, status and image download,
  including response-body reads. Poll/download retries reuse the same task ID.
- Return task state from the authenticated product Studio endpoint so reopening
  the screen can resume. Task ownership is checked on every operation.
- iOS shows progress, retrieves completed variations, pauses polling when the
  screen/app is inactive, and resumes on return. A transient connection failure
  offers “Check progress”, not a new paid generation.
- Kling can continue rendering while iOS is closed. Final download/settlement
  resumes when the app checks progress; this does not promise background push.
- Old TestFlight builds receive an actionable update-required response instead
  of entering the old multi-minute path. A new TestFlight build is necessary.

## Local verification and rollout

With stubbed Kling responses and a disposable Postgres database, check lost
responses, slow/failed polls and downloads, concurrent starts/settlements,
single charging per variation, no charge for failures, credit contention with
text generation, reservation expiry, and account deletion. Compile/run iOS.

Deploy only after separate authorization: migration, API, then the new app
build. Verify production using a separately authorized real generation and
correlate task timings with Vercel/Kling logs. Current production logs have not
been inspected; the 170-second code path matches the reported 2–3-minute wait
but does not prove which network layer produced the observed error.

## Separate existing quality issue

The current image adapter sends the product cutout to a diffusion model. It
does not implement SPEC §8's original-pixel compositing, despite the iOS source
comment claiming that it does. The timeout fix cannot certify label fidelity
or automatically mark generated images as marketplace compliant.

## Interim timeout/cache change (owner request, 2026-09-20)

The owner subsequently requested a 200-second timeout and caching. Implemented
without schema changes:

- iOS Studio POST timeout is 200 seconds. A 3/5-image batch makes separate
  requests, reports progress, and stops remaining submissions on failure or
  screen dismissal. Saved images are reloaded before retry and skipped.
- The provider adapter has separate submit/status/download operations with
  20-second HTTP deadlines covering response bodies. Its total image-work
  budget is 180 seconds, leaving headroom for storage/settlement within the
  app's 200 seconds. This is still a synchronous request, not a durable job.
- A bounded process-local cache retains task IDs and uncertain submissions.
  Concurrent requests in the same process share generation, save and charge.
  It cannot deduplicate across Vercel instances or survive a restart.
- Existing assets are the durable per-product result cache. A concurrently
  contributed Supabase content cache is preserved, scoped to the organization,
  cutout, scene/prompt, model and variation. A hit avoids rendering and another
  charge. A storage outage is not treated as a miss that incurs provider cost.
- Provider failures are server errors, not insufficient user credits; logs
  contain phase/task ID/recovery state, not photos, credentials or image URLs.

Compatibility: deploy the updated API before the new iOS build. Old builds can
request one image; old multi-image requests receive HTTP 426 with an update
instruction. The new app detects old backends that ignore the variation index.
Neither the API nor a new TestFlight build has been deployed by this work.

Validation: TypeScript typecheck, production API build and all 119 backend tests pass (including
image submission cost, cache isolation, partial recovery and concurrent retry
cases). Changed Swift files pass syntax parsing. The new Swift tests have not
run: automatic approval review rejected simulator access because its usage
quota was exhausted. Syntax parsing is not an iOS build or test. Earlier
preparatory local unauthenticated route smoke checks passed; the updated
timeout/cache flow has not been exercised on the simulator or a real provider.

Remaining: database migration, durable task orchestration, atomic asset/credit
settlement across instances, and short iOS polling. This interim change does
not guarantee that a slow provider always finishes within 200 seconds, nor
exactly-once charging across multiple instances. No real Kling generation was
called and no production data or configuration was changed.
