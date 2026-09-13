# Proposed database change: generation settlement

This is a proposal for the owner's approval under SPEC §0. It is **not an
applied migration**. No live database is changed by this document.

## Problem reproduced in the current implementation

`generate.ts` charges each marketplace before `assets` and `generations` are
persisted. A later database failure returns HTTP 500 after the debit; retrying
starts the provider calls and debits again. `assertCanAfford` and `appendEntry`
also run as separate HTTP queries, allowing two requests to spend the same
balance. An in-process mutex would not protect separate Vercel instances.

## Proposed migration

Add one request table and three service-role-only Postgres functions. Existing
product, asset, generation and ledger tables remain the authoritative records.
No client writes to the new table are permitted.

```sql
create table generation_requests (
  id uuid primary key,
  org_id uuid not null references organizations(id) on delete cascade,
  product_id uuid not null references products(id) on delete cascade,
  input_hash text not null,
  input jsonb not null,
  status text not null check (status in ('running', 'completed', 'failed')),
  reserved_credits integer not null check (reserved_credits >= 0),
  lease_token uuid not null,
  lease_expires_at timestamptz not null,
  result jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index generation_requests_active_org_idx
  on generation_requests (org_id, lease_expires_at) where status = 'running';
alter table generation_requests enable row level security;
```

1. `begin_generation(request_id, org_id, product_id, input_hash, input,
   quoted_credits)` locks the organization row (`SELECT ... FOR UPDATE`), checks
   that its owner is active and the product belongs to it, and compares the
   ledger sum minus other unexpired reservations with the quote. The request
   UUID and hash make retries immutable. A completed identical request returns
   its saved result. A running request returns its current state, preventing a
   second provider call. A failed/expired request may acquire a new random
   lease token. Reserving credits does **not** debit the append-only ledger.
2. `complete_generation(request_id, lease_token, assets, usages, result,
   credits_to_charge)` takes the same organization lock, validates the active
   account and lease, and checks `0 <= credits_to_charge <= reserved_credits`.
   One transaction inserts the assets and model usage records, appends the
   successful debit with the derived `balance_after`, stores the exact response
   (including persisted asset IDs), and marks the request completed. A rollback
   rolls all these writes back together. A repeated completed commit returns
   the stored response and writes no second debit. Model usage rows must carry
   the actual credits for that call, and unknown USD cost remains SQL NULL.
3. `fail_generation(request_id, lease_token)` takes the same lock and ends the
   matching running lease, freeing its reservation. It never refunds a debit
   because completion is the only operation allowed to debit. Stale workers
   cannot complete a newer lease.

All functions must be declared with a fixed `search_path`, fully qualify table
references, revoke EXECUTE from PUBLIC/anon/authenticated, and grant EXECUTE
only to service_role. Runtime code must stop using non-transactional
`chargeCredits` for generation after the migration is deployed.

Account deletion must acquire the organization lock before marking the account
deleted and removing data, so an in-flight commit either completes before
cleanup or is rejected after it. A separate check in TypeScript cannot close
that race. Credit grants/reversals must acquire the same organization lock so
their recorded balances serialize with debits.

## Billing additions still required

This request table solves generation idempotency and concurrent spending only.
The current ledger has no unique Apple transaction identifier per grant, no
credit bucket/expiry attribution, and no notification inbox for deduplication.
StoreKit billing needs a separately reviewed extension for: verified transaction
and notification IDs, plan versus top-up buckets, monthly expiry/annual monthly
grants, and refund linkage. Do not repurpose `original_transaction_id` as a
unique renewal ID: all renewals in a subscription chain share that ID.

## Validation before deployment

Use a disposable local Postgres database and stubbed providers to prove:

- Two requests cannot reserve/spend a balance sufficient for only one.
- Retrying the same UUID/input returns the same asset IDs and one debit;
  changing input for that UUID returns conflict.
- Failures injected between every settlement write leave no debit or partial
  assets; provider failures charge only persisted successful output.
- A worker whose lease expired cannot commit over a newer worker.
- Account deletion and settlement cannot recreate a deleted account's data.
- Refunds can create a negative balance, block new generation, and preserve
  ledger history; annual credits are granted monthly and plan credits expire.

Deployment order: approved migration in a staging database, concurrency/failure
tests, API deploy, then production migration and end-to-end validation under
separate deployment authorization. Until that validation is complete, paid
generation remains a submission blocker.
