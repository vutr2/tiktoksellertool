# Localization review — Codex, 26 September 2026

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
