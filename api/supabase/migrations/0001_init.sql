-- ListingForge — Milestone 1 schema (SPEC §9).
-- Establishes the full data model now; credit/subscription logic and the
-- credit_ledger immutability trigger arrive in M5 (see TODO markers).

create extension if not exists "pgcrypto";

-- Users -----------------------------------------------------------------------
create table if not exists users (
  id            uuid primary key default gen_random_uuid(),
  apple_user_id text unique,
  email         text,
  deleted_at    timestamptz,
  created_at    timestamptz not null default now()
);
create index if not exists users_email_idx on users (email) where deleted_at is null;

-- Organizations ---------------------------------------------------------------
create table if not exists organizations (
  id            uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references users(id) on delete cascade,
  name          text not null,
  created_at    timestamptz not null default now()
);
create index if not exists organizations_owner_idx on organizations (owner_user_id);

-- Products --------------------------------------------------------------------
create table if not exists products (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references organizations(id) on delete cascade,
  name             text not null,
  category         text,
  source_photo_url text,
  cutout_url       text,
  attributes       jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now()
);
create index if not exists products_org_idx on products (org_id);

-- Assets ----------------------------------------------------------------------
create table if not exists assets (
  id                    uuid primary key default gen_random_uuid(),
  product_id            uuid not null references products(id) on delete cascade,
  type                  text not null check (type in ('image','title','description','script')),
  marketplace           text not null,
  content               text,
  url                   text,
  derived_from_asset_id uuid references assets(id) on delete set null,
  validation_status     text not null default 'pending',
  violations            jsonb not null default '[]'::jsonb,
  created_at            timestamptz not null default now()
);
create index if not exists assets_product_idx on assets (product_id);

-- Generations -----------------------------------------------------------------
create table if not exists generations (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references organizations(id) on delete cascade,
  asset_id          uuid references assets(id) on delete set null,
  provider          text,
  model             text,
  credits_charged   integer not null default 0,
  actual_cost_usd   numeric(10,4),
  latency_ms        integer,
  langfuse_trace_id text,
  created_at        timestamptz not null default now()
);
create index if not exists generations_org_idx on generations (org_id);

-- Credit ledger (append-only — SPEC §9). --------------------------------------
-- TODO(M5): add a trigger that blocks UPDATE/DELETE to enforce immutability.
create table if not exists credit_ledger (
  id                      uuid primary key default gen_random_uuid(),
  org_id                  uuid not null references organizations(id) on delete cascade,
  delta                   integer not null,
  reason                  text not null,
  balance_after           integer not null,
  original_transaction_id text,
  created_at              timestamptz not null default now()
);
create index if not exists credit_ledger_org_idx on credit_ledger (org_id, created_at);

-- Subscriptions ---------------------------------------------------------------
create table if not exists subscriptions (
  original_transaction_id text primary key,
  org_id                  uuid not null references organizations(id) on delete cascade,
  product_id              text not null,
  tier                    text not null,
  status                  text not null,
  expires_at              timestamptz,
  credits_per_month       integer not null default 0,
  updated_at              timestamptz not null default now()
);
create index if not exists subscriptions_org_idx on subscriptions (org_id);

-- Email OTP (not in §9; required by the app's custom email endpoints). ---------
create table if not exists email_otps (
  id          uuid primary key default gen_random_uuid(),
  email       text not null,
  code_hash   text not null,
  expires_at  timestamptz not null,
  attempts    integer not null default 0,
  consumed_at timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists email_otps_lookup_idx on email_otps (email, created_at desc);

-- Row Level Security: deny-by-default on every table. The API uses the service
-- role key, which bypasses RLS. Client-direct policies land in a later milestone.
alter table users         enable row level security;
alter table organizations enable row level security;
alter table products      enable row level security;
alter table assets        enable row level security;
alter table generations   enable row level security;
alter table credit_ledger enable row level security;
alter table subscriptions enable row level security;
alter table email_otps    enable row level security;
