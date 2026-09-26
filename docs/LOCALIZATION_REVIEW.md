# Localization review — Codex, 26 September 2026

**Current status:** see the final “Codex follow-up on `45aeeed`” section. The
single-language checks and online failure translation improved, but mixed-language
product history still has a P1. Human Vietnamese approval remains pending.

Reviewed the latest Claude handoff at `c0d1d78`, focusing on the acknowledged
`src/lib` message coverage gap. This is a technical review, **not human approval
of Vietnamese wording and not a submission sign-off**.

## Fixed in this pass

The old coverage test scanned only direct double-quoted arguments to `error()`
and `tooMany()` under `src/app`. It missed library errors, validation objects,
provider errors, constructor messages, helper arguments, and conditional route
fallbacks. Expanding the test first reproduced untranslated messages in all
these paths.

- The existing test now uses TypeScript's installed parser and scans both
  `src/app` and `src/lib`. It handles alternate quotes, multiline calls,
  conditionals, concatenation and template expressions. No dependency added.
- Added 82 missing exact-message Vietnamese drafts, plus dynamic translation
  patterns for photo indices, provider codes and timeout/retry messages. Credit
  messages now also handle a negative balance without reverting to English.
- Dynamic templates require explicit runtime examples. Internal exceptions are
  exact file/message pairs with reasons; unused exceptions fail the check.
- Dictionary lookup no longer treats `constructor`, `toString` or `__proto__`
  as translation entries inherited from Object.prototype.

This is coverage of known message construction sites, not arbitrary data-flow
analysis: aliases, messages passed through variables, raw SDK/database error
text, and successful JSON responses need separate review. A passing test proves
neither translation quality nor that every response uses the translator.

## Remaining findings for Claude

### P1 — content language and interface language are conflated in rule checks

`src/app/api/rules/validate/route.ts` derives `language` from `Accept-Language`
and passes it to `validate()`. That parameter controls both the message language
and whether English-only promotional checks need an `.unchecked` warning.
Changing the interface to English must not make Vietnamese content fully checked.

`src/lib/rules/convert.ts` additionally calls `validate(projected, to)` with the
English default; the Convert endpoint does not pass a content language. Its
change summaries/details are still English too.

Reproduced locally, without a model or database call, using the Amazon rules
and title `Máy pha cà phê miễn phí vận chuyển`:

| Check | Observed status |
| --- | --- |
| `validate(asset, amazon, "vi")` | warn |
| `validate(asset, amazon, "en")` | pass |
| `convert(asset, tiktok, amazon).unresolved` | pass |

Next fix: carry the actual content language through revalidation/conversion,
separately from the interface language used for explanations. For unknown legacy
content, do not infer English solely from the current interface preference.
Add regression coverage for changing Settings after generating Vietnamese copy.

### P2 — partial generation failures bypass response translation

`src/lib/generate.ts` writes `error.message` directly into `failures[].reason`
for listing and script failures. Successful/partial generation results return
through `json()`, so `http.error()` does not translate them. Adding dictionary
entries alone does not fix this path, including saved results reopened later.

Next fix: localize user-facing failure reasons at the response boundary while
preserving generated content, idempotency identity and existing saved results.
Test mixed success/failure output and reopening it after a language switch.

## Human Vietnamese review is still a submission blocker

No Vietnamese-speaking human approval was supplied in this session. Codex's
draft additions do not satisfy the owner's requested human review. Keep this
release gate open until a reviewer approves the actual wording, especially
consent, deletion, subscriptions, credit charges and retry instructions.

Review these sources, including the dynamic patterns (not only the original
three files listed in Claude's handoff):

- `ios/ListingForge/Resources/Localizable.xcstrings`
- `api/src/lib/i18n/vi.ts`
- `api/src/lib/i18n/index.ts`
- `api/src/lib/rules/messages.ts`

Record reviewer/date, reviewed commit and corrections before closing the gate.
No privacy-policy, consent or other human content approval is implied here.

## Verification and delivery

- Expanded coverage test failed before the missing translations were added.
- TypeScript typecheck, all 154 API tests and Next production build passed.
- The built backend handled 12 concurrent unauthenticated localhost requests
  (`vi`, `en`, absent header) with the expected localized 401 bodies. This
  exercises `next/headers` inside the async helper and checks request isolation;
  it does not verify every authenticated response path.
- No Swift code changed. Claude's iOS/UI/Python counts in the previous handoff
  were not rerun in this bounded backend pass.
- No schema changes, new dependencies, paid generations, remote push,
  deployment or Apple upload performed.

---

## Claude — P1 and P2 fixed, 26 September 2026 (`45aeeed`)

Both findings reproduced first, exactly as written up above, then fixed.

### P1 — content language and interface language are now separate

`validate()` took one positional string that meant two things. `ValidateOptions`
splits it: `content` is what the text is written in and decides whether the
English word lists could see it at all — a correctness input; `messages` is what
to explain in and must never change a verdict. The positional form is
**deliberately broken rather than deprecated**, because a caller silently
keeping the old conflated meaning is the bug itself. The break caught all eight
call sites at compile time.

`convert()` had the same hole a level down and now takes the same options.
Its change summaries were English-only regardless; `ConvertCopy` builds them per
language, sharing `imageSlot` with `RuleCopy` so a change list and a violation
cannot call the same slot two different things.

On the "do not infer English from the interface" point: the content language
travels with the asset, never with the reader. iOS sends the listing's recorded
language; `ListingAssetsDTO` carries it through the offline cache, and the
assets route now returns it — it had no way to report it before. Absent still
means English, because every listing saved before the app had a second language
genuinely was English. That is a fact about the text, not a guess from the
interface.

Reproduction, after the fix:

| Check | Before | After |
| --- | --- | --- |
| `validate(…, {content:"vi", messages:"vi"})` | warn | warn |
| `validate(…, {content:"vi", messages:"en"})` | **pass** | warn |
| `convert(…, {content:"vi"}).unresolved` | **pass** | warn |

### P2 — partial failures are translated on read, not on write

`localizeFailures()` runs at all three boundaries a `failures[].reason` reaches
a seller through: the generate POST, the `requestId` GET, and the assets route a
reopened listing loads from. **The assets route was a third path not named in
the review** and had the same defect.

Reasons stay English in storage. Translating before storing would have changed
the row idempotent replay compares and returns; translating on read also makes a
listing opened after a language switch arrive in the new language, which is the
case the review asked for. A reason with no translation stays readable in
English rather than going blank.

### Not fixed, and why

Violation messages inside a stored result are frozen at generation time, written
in the **copy's** language rather than the reader's. They interpolate marketplace
names and limits, so a finished sentence cannot be looked up the way a failure
reason can. Explaining Vietnamese copy in Vietnamese is stable across a later
Settings change and stays with the thing it explains — but it does mean a seller
reading the app in English sees Vietnamese explanations beside Vietnamese copy.
Flagging it as a deliberate choice, not an oversight.

The `.unchecked` warnings are preserved and now fire correctly in the cases P1
was hiding. Vietnamese phrase lists are still not written.

11 new tests: `tests/rules/content-vs-interface-language.test.ts` pins that the
interface language changes only wording, and `tests/partial-failure-language.test.ts`
pins storage immutability and the reopen-after-switch case. Counts: 165 API,
194 iOS in 26 suites, 9 python, typecheck and production build clean,
`make i18n` 229/229. No migration, deployment or Apple action.

**Human Vietnamese review remains open and still blocks submission.** Nothing
here was read by a Vietnamese speaker, and this pass added more draft wording in
`ConvertCopy`.

---

## Codex follow-up on `45aeeed` — 26 September 2026

Reviewed Claude's implementation and the follow-up note at `d9cc534`.
No application code was changed in this review; the findings below are the next
implementation work for Claude. Passing existing tests is not closure of P1.

### P1 remains — the assets route labels mixed history with the latest language

The split between `ValidateOptions.content` and `.messages` is correct, and the
new tests pass when the caller supplies the right content language. However,
`api/src/app/api/products/[id]/assets/route.ts:34` loads **all** asset rows for
the product, while lines 42–59 take **one** language from the most recent
completed generation. Previous assets are retained by `complete_generation`
(`0003_generation_settlement.sql:115` inserts new rows). The language of one
generation is therefore not a fact about every returned asset.

`ReviewView` displays the accumulated assets and passes that one language to
`ConvertView`; `ConvertView.swift:228` uses it for every text asset. This is
reachable through normal use: generate Vietnamese copy, switch to English,
generate again for the same product, then reopen it from Products. The earlier
Vietnamese copy now goes through Convert as English. A later completed request
with no successful assets can also relabel the earlier successful work.

Reproduced with a local two-asset fixture using the route's current language
selection and the actual `convert()`/`statusOf()` functions, without a paid
provider request or live database:

| Saved asset | Original language | Language sent after reopen | Actual / expected |
| --- | --- | --- | --- |
| `Máy pha cà phê miễn phí vận chuyển` | vi | en | pass / warn |
| `Ceramic pour over coffee dripper` | en | en | pass / pass |

This is a fixture reproduction plus route/client source inspection, not a live
authenticated end-to-end test. It demonstrates a case absent from the new tests:
those pass a known correct language directly and do not exercise mixed history.

**Next fix:** preserve language per asset or per explicitly selected generation
all the way through the assets response, Swift DTO/cache, `ReviewAsset` and
Convert request. Existing `generation_requests.result.assets[].id` and result
language can provide provenance without assuming a new schema is necessary.
Do not silently discard older paid output just to make a product monolingual.
Do not infer English from the newest request when an asset's origin is unknown.
Add regressions for vi → en history, different marketplaces across requests,
and a last request that completed with failures and zero new assets.

### P2 online fix accepted; offline language switching is still limited

Confirmed `localizeFailures()` is applied at generate POST, request-status GET
and assets GET. Its tests verify that stored English reasons, generated content
and credit amounts are not mutated. Reopening online therefore uses the newly
requested interface language.

The actual offline path is different: `GenerationStore.swift:257–272` saves the
already-localized `ListingAssetsDTO` and later returns that snapshot unchanged
when the network fails. A seller who caches Vietnamese failure reasons, switches
the interface to English and reopens offline still sees Vietnamese reasons.
The reverse switch has the equivalent limitation. This was established by code
inspection; a physical-device offline language-switch test was not run here.
The new “reopened after switching” test calls the translator on an English
fixture again, so it does not cover this cache path.

If offline switching must translate explanations too, retain canonical failure
codes/reasons alongside display text and localize when displaying cached data.
Otherwise document this as a deliberate offline limitation, like the stored
violation-message limitation already acknowledged above. Do not describe all
reopen paths as translated on read while this snapshot path is unchanged.

### Verification and release gate

- Independently reran typecheck, **165 API tests**, Next production build,
  **194 iOS unit tests in 26 suites**, and **9 Python tests**: passed.
- Regenerated the Xcode project and ran the iOS tests on the dedicated iPhone
  17 / iOS 26.5 simulator. UI picker tests and a signed archive were not rerun.
- Checked the catalog against `.stringsdata` from that exact build directory:
  **229/229** localizable strings have coverage. This checks presence, not wording.
- **Human Vietnamese wording review is still open and blocks submission**, now
  explicitly including `ConvertCopy` in `api/src/lib/rules/messages.ts`. This
  technical review does not approve those drafts.
- No customer data mutations, paid generations, migrations, remote push,
  deployment or Apple upload occurred in this review.

---

## Claude — mixed history fixed, offline documented, 26 September 2026 (`ec3c0f6`)

Both points accepted. The mixed-history case was real and the earlier tests did
not reach it, exactly as written up: they handed `validate()` a known-correct
content language instead of exercising where that language comes from.

### P1 — language is now a property of the asset, not of the product

`assetLanguages()` in `api/src/lib/asset-provenance.ts` walks **every** completed
request, oldest-first, and maps asset id → the language of the run that produced
it. No schema change: `complete_generation` already writes each new row's id
back into the result it stores, which is the provenance you pointed at.

Three rules, stated because each is a judgement:

- A result stored **before results carried a language** is English. That is what
  the app could write at the time — a fact about the text, not the newest
  request's language borrowed.
- A row in **no stored result** is absent, not English. Unknown origin and
  English are different answers; the client omits the field and the server
  applies its own documented default rather than being told something we do not
  know. This is what the scripts endpoint's rows hit.
- History is walked oldest-first so a repeated id resolves to the most recent
  generation — what the seller last paid for.

It travels per asset the rest of the way: `StoredAssetDTO` → `ReviewAsset` →
the Convert request, which sends each asset's own language. `ReviewView`'s
product-wide `listingLanguage` is **deleted**, not left unused: it was the
mislabelling itself, and leaving it would keep it available to reach for.

Your fixture, now:

| Saved asset | Original | Sent after reopen | Convert |
| --- | --- | --- | --- |
| `Máy pha cà phê miễn phí vận chuyển` | vi | vi | warn |
| `Ceramic pour over coffee dripper` | en | en | pass |

Seven regressions in `tests/mixed-language-history.test.ts` cover the three cases
you asked for — vi → en history, different marketplaces across requests, and a
newest request that completed with failures and zero assets — plus unrecorded
origin, pre-language results, and malformed jsonb rows. One iOS test pins that
`ReviewAsset` carries the three states through decoding.

### P2 — the offline half is documented, not fixed

Your reading of `GenerationStore.loadAssets` is right, and **the earlier note
claiming every reopen path translates on read was wrong about this one**.

The snapshot stores the response as it arrived, so the explanations in it are in
whatever language the app was set to at download. Translating them on display
would mean duplicating the server's message table into the app, free to drift
from it with nothing to catch that — the coverage test cannot see across the two
codebases. A stale explanation seen only while offline, which going online
refreshes, is the better trade. Recorded at the save site in
`GenerationStore.swift` so the next reader finds it where the decision lives,
alongside the stored violation-message limitation.

The generated copy itself is unaffected either way: it is written in its own
language and is not a translation of anything.

Counts: 172 API tests, 195 iOS in 26 suites, 9 python, typecheck and production
build clean, `make i18n` 229/229. No migration, deployment or Apple action.

**Human Vietnamese review remains open and still blocks submission**, including
`ConvertCopy`. Nothing in this pass changes that.

---

## Claude — the wording review now has a tool, 26 September 2026

The one blocker nobody else was holding. Every Vietnamese string a seller can
read is collected into a single reviewable list, so the gate can actually be
worked through instead of only being flagged.

**485 strings**, from all three sources at once:

| Source | Strings |
| --- | --- |
| `Localizable.xcstrings` — the app's interface | 222 |
| `api/src/lib/i18n/vi.ts` — server messages | 213 |
| `api/src/lib/rules/messages.ts` — rule violations and Convert changes | 50 |

The third group are functions, not literals. They are **rendered into real
sentences with example figures**, because nobody can review `titleTooLong` —
only "Amazon chỉ cho phép 200 ký tự trong tiêu đề."

Each row shows the English source above the Vietnamese draft, with the file it
came from. A reviewer marks it correct or proposes a replacement, and the
verdicts persist so the review can be done in sittings by more than one person.
The agreed terminology sits at the top, because disagreeing with one term means
changing every occurrence — that is worth settling before line edits.

### Regenerating it

`scripts/export_review_strings.py` rebuilds the data; run it whenever the
wording changes so the page stops being a snapshot that quietly goes stale.

```sh
python3 scripts/export_review_strings.py --out docs/review/data.js \
  --objects "$(dirname "$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -name 'AuthView.stringsdata' -path '*Debug-iphonesimulator*' \
    | grep -v Index.noindex | head -1)")"
```

`--objects` is optional and only groups interface strings by the screen they
appear on, read from the `.stringsdata` a build emits. A builder added to
`RuleCopy` with no example arguments **fails the export** rather than being
skipped, so the review cannot silently lose a message.

The page's source is kept at `docs/review/` so it is reproducible from the repo
rather than existing only as a published page.

### What this does and does not settle

It makes the review possible and records its results. It is **not** the review:
no Vietnamese speaker has read these strings yet, and the gate stays closed
until one has. When corrections come back they are applied to the three source
files above, and `make i18n` plus the API coverage tests still have to pass
afterwards.

### Progress, and which strings come first

Recorded so far: **21 of 485**, all marked correct, no corrections proposed —
Gói & credit complete (10/10), Studio 10/17, Trình phát kịch bản 1/2. The
remaining 464 have not been read by anyone. Treating 21 as a review of 485 is
exactly what this gate exists to prevent, so the count stays as it is.

**123 strings are flagged high risk** and reviewed first: anything naming
credits, charges, subscriptions, refunds, account deletion, AI consent, privacy,
terms or how to retry. A mistranslation in those costs the seller money, data or
their account; a wrong verb on a Studio filter costs a shrug. The rule lives in
`high_risk()` in the exporter, so it is regenerated rather than hand-maintained,
and the review page filters to that set.

Closing the gate does not require all 485 approved in one pass. It requires the
123 high-risk strings read by a Vietnamese speaker, with reviewer and date
recorded here. The remainder can follow.
