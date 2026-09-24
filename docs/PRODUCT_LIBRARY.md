# Products library — 25 September 2026

Products now uses two-column square photo cards with the name below and a
three-dot menu. The menu offers Hide/Show and Delete. Select at the top left
enables multiple selection, with Select all in the library menu and Hide/Show
selected and Delete selected at the bottom. Hidden products have a separate
view accessible from the library menu. Hiding preserves photos and listings.

Deletion requires confirmation. The app removes only server-confirmed successes;
failed items remain available to retry. It clears the corresponding Studio,
listing, draft and SwiftData caches, and persists deleted IDs so an old offline
mirror does not bring a deleted card back. Exported Photos-library images remain.

## Backend

- `PATCH /api/products/:id` accepts `{ "hidden": true | false }` and merges the
  flag into the existing attributes with an optimistic concurrency check.
- `DELETE /api/products/:id` verifies ownership, checks for active listing
  reservations, marks the product as deleting, removes its private photo folder
  (all pages and nested folders), then deletes the product row. Related assets
  cascade. A cleanup failure leaves a visible, retryable product.
- `GET /api/products/:id/thumbnail` authenticates the account and serves a
  private, resized preview. Originals and Studio photos remain private.
- `GET /api/products?page=N` returns 100 items plus `hasMore`. The app loads all
  pages so older products do not disappear behind the previous 100-item limit.

No database migration or new dependency is required. Credit history remains;
deletion does not refund generation credits. The shared, account-scoped Studio
content cache is separate from product folders and is cleared by account
deletion, not individual product deletion. Studio settlement across concurrent
server instances still has the limitation documented in
`STUDIO_ASYNC_PROPOSAL.md`; this feature does not implement that proposal.

## Delivery and version

Deploy the backend changes before distributing the new app: older deployments
do not have the hide/delete/thumbnail endpoints. Local code changes do not update
an installed TestFlight build.

`project.yml` now supplies `CFBundleShortVersionString` from `MARKETING_VERSION`
and `CFBundleVersion` from `CURRENT_PROJECT_VERSION`, replacing XcodeGen's
previous literal 1.0/1 defaults. Current project settings are 2.1.0 (3).
Generate the project and create a new archive; existing archives are unchanged.

## Local verification

- Backend production build and 135 backend tests passed, including ownership,
  active credit reservation, recursive deletion and failed-cleanup checks.
- 185 iOS unit tests in 25 suites passed.
- Debug and Release simulator builds; Products preview uses the isolated
  `--demo --screen products` fixture and does not delete customer data.
- No production deletion, deployment or TestFlight upload performed.
