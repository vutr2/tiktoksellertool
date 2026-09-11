# ListingForge API

Next.js 15 (App Router, API routes only) backend for the ListingForge iOS app.
Milestone 1 scope: auth (Sign in with Apple + email OTP) and account deletion.

## Setup

```bash
npm install
cp .env.example .env   # fill in Supabase + session + email values
```

Apply the schema to your Supabase project (SQL editor or `supabase db push`):

```
supabase/migrations/0001_init.sql
```

## Run

```bash
npm run dev   # serves on http://localhost:3000 (matches the app's API_BASE_URL)
```

## Endpoints

| Method | Path | Auth | Returns |
|---|---|---|---|
| GET | `/api/health` | — | `{ ok: true }` |
| POST | `/api/auth/apple` | — | `{ token, user }` |
| POST | `/api/auth/email/request-code` | — | `{}` |
| POST | `/api/auth/email/verify` | — | `{ token, user }` |
| POST | `/api/account/delete` | Bearer | `{}` |

All error responses use the shape `{ "error": "message" }` to match the iOS
`APIClient`.

## Local smoke test

```bash
curl localhost:3000/api/health
curl -X POST localhost:3000/api/auth/email/request-code \
  -H 'content-type: application/json' -d '{"email":"you@example.com"}'
# grab the code from the email (or server console when RESEND_API_KEY is unset)
curl -X POST localhost:3000/api/auth/email/verify \
  -H 'content-type: application/json' -d '{"email":"you@example.com","code":"123456"}'
# → { "token": "...", "user": { "id": "...", "email": "you@example.com" } }
curl -X POST localhost:3000/api/account/delete -H 'authorization: Bearer <token>'
```
