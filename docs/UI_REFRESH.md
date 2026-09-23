# Workflow UI refresh — 24 September 2026

The Product details, Marketplaces, Review, Convert, Paywall and Studio screens
use the supplied mockups' warm background, white bordered cards, compact
headers, status pills and black bottom actions. `WorkflowStyle.swift` owns the
shared styling, including adaptive status colours for dark mode.

The camera's dark appearance is scoped to its controls so it no longer forces
the following sheets into dark mode. Draft recovery, saved Studio photos,
credit quotes and StoreKit purchase handling remain connected to the existing
stores. A restored selection requiring another plan opens the paywall before
generation.

## Behaviour behind the design

- Prices, annual savings and trial eligibility come from StoreKit. The shipping
  paywall does not promise the sample mockup's trial to ineligible customers.
- Review shows actual saved Studio photos and expandable text checks. A saved
  photo has a **Saved** badge; this is not a marketplace compliance result.
- Convert checks saved titles and descriptions against another marketplace's
  server rules. It does not edit image pixels or silently replace listing copy.
  Continuing opens marketplace selection and a credit quote before generation.
- Unrendered Studio styles use illustrations; completed styles show the
  customer's saved photo. These are not stock photographic scene previews.

## Local preview

Build the Debug scheme, install it on a simulator, then run:

```sh
xcrun simctl launch --terminate-running-process booted com.ctt.listingforge --demo --screen studio
```

Screen names: `details`, `marketplaces`, `studio`, `review`, `convert`, `paywall`.
The fixture transport stays local and rejects unhandled requests. Demo sessions
do not overwrite Keychain login, request camera access or start StoreKit calls.
The paywall preview uses sample prices because `simctl launch` does not load the
Xcode StoreKit test configuration; verify actual purchasing through the normal
Xcode scheme. All preview scaffolding is excluded from Release.

## Validation

- Debug simulator build and all six preview screens launched successfully.
- 185 iOS unit tests in 25 suites passed.
- Release simulator build passed; no App Store archive or TestFlight upload
  is implied by this check.
