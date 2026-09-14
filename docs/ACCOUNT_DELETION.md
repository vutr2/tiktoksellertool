Account deletion implementation — 14 September 2026

`POST /api/account/delete` accepts the current bearer session and an optional JSON body:

```json
{ "identityToken": "fresh Apple identity token", "authorizationCode": "fresh Apple authorization code" }
```

Email accounts can send `{}`. Apple-linked accounts return HTTP 428 when reauthentication is needed or Apple exchange/revocation fails. The iOS confirmation flow can obtain fresh native Apple credentials and retry. The server verifies both the supplied identity token and the identity returned by the code exchange against the existing Apple subject before revoking the refresh/access token. It does not trust the client's email address to link Apple accounts.

If Apple credentials cannot be obtained, the person may explicitly choose `{ "skipAppleRevocation": true }`. The backend still deletes account data and returns `{ "appleRevocationRequired": true }`, so the app explains manual revocation in Apple Account settings. This fallback follows [Apple TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple); account deletion cannot be permanently blocked merely because a usable Apple token is missing.

The backend requires `APPLE_AUDIENCE`, `APPLE_TEAM_ID`, `APPLE_KEY_ID` and the Sign in with Apple `.p8` key as `APPLE_PRIVATE_KEY` for automatic revocation. Escaped PEM newlines are accepted. These are server-only credentials. Native authorization codes are single-use and valid for five minutes, so an old code from initial login is not reused. [Apple token validation](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens)

Cleanup behavior:

- `begin_account_deletion(p_user_id)` from migration 0002 locks owned organizations before setting `users.deleted_at`, using the same organization lock as generation settlement. Normal API sessions then fail. The deletion endpoint alone continues accepting the signed session to retry unfinished cleanup. Deploy the approved migration before this route; a missing RPC fails closed.
- Private cutout cleanup visits every page and nested multi-angle folder, then removes object batches. Storage lookup/list/remove errors stop completion.
- Product deletion cascades to assets and generation request content. Recorded Langfuse trace IDs are submitted for provider deletion before generation records are removed. Workspace names, sign-in OTP records and user email/Apple subject are scrubbed; every database error is checked.
- Append-only credit ledger and subscription audit records are retained with the scrubbed user/workspace for refund accounting, as required by SPEC. This is not a claim that no transaction-related data remains.
- Deleting the app account does **not** cancel an Apple subscription. The app must explain this and provide Apple subscription management where applicable.

Langfuse cleanup uses the [documented trace deletion API](https://langfuse.com/docs/administration/data-deletion), batching at most 50 recorded trace IDs. Configured `LANGFUSE_BASE_URL`, `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` must address the project holding those IDs. If the provider rejects a request, the account remains unavailable and the recorded IDs remain for retry. Provider erasure is asynchronous; Langfuse states it usually completes within 15 minutes, so the UI/policy must not promise immediate removal from every provider system. [Langfuse API limits](https://langfuse.com/faq/all/api-limits)

Before production submission, the operator must review/purge historical traces that lack a recorded generation trace ID (including failures from earlier builds), confirm the configured provider retention policy, and describe Anthropic's actual retention terms. New tracing must omit seller content; deleting database rows alone cannot erase unlinked historical provider records. No live deletion or production credential validation was performed in this change.

Offline checks in `api/tests/account-deletion.test.ts` cover successful PII cleanup, each failure stage, mandatory Apple confirmation, manual fallback, token exchange/revocation subject matching, tombstoned JWT rejection, storage pagination/nesting, database failure propagation and trace deletion batching/error handling. Complete a real non-production Apple sign-in/delete/re-register flow on a device, test interrupted cleanup/retry, and verify provider records before claiming production deletion readiness.
