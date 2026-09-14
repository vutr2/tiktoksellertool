-- Owner-approved LOCAL StoreKit accounting schema.
-- Do not deploy until paid-credit expiry policy is resolved; see docs/SUBMISSION_READINESS.md.
create table public.apple_transactions (
  transaction_id text primary key,
  original_transaction_id text not null,
  org_id uuid not null references public.organizations(id),
  product_id text not null,
  app_account_token uuid not null,
  purchase_date timestamptz not null,
  expires_date timestamptz,
  revocation_date timestamptz,
  environment text not null,
  signed_date bigint not null,
  tier text,
  grant_schedule jsonb not null,
  payload_hash text not null,
  created_at timestamptz not null default now()
);
create index apple_transactions_org_idx on public.apple_transactions(org_id);
create index apple_transactions_original_idx on public.apple_transactions(original_transaction_id);
create table public.apple_notifications (
  notification_uuid text primary key,
  transaction_id text references public.apple_transactions(transaction_id),
  notification_type text not null,
  subtype text,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  processing_error text
);
create table public.credit_grants (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id),
  transaction_id text not null references public.apple_transactions(transaction_id),
  billing_period_start timestamptz not null,
  billing_period_end timestamptz,
  kind text not null check(kind in ('plan','topup','trial')),
  amount integer not null check(amount>0),
  expires_at timestamptz,
  expired_amount integer not null default 0,
  reversed_amount integer not null default 0,
  unique(transaction_id,billing_period_start,kind)
);
create unique index credit_grants_trial_once on public.credit_grants(org_id) where kind='trial';
create index credit_grants_org_idx on public.credit_grants(org_id);
create table public.credit_allocations (
  ledger_entry_id uuid not null references public.credit_ledger(id),
  grant_id uuid not null references public.credit_grants(id),
  amount integer not null check(amount>0),
  primary key(ledger_entry_id,grant_id)
);
alter table public.subscriptions add column latest_transaction_id text;
alter table public.subscriptions add column signed_date bigint;
alter table public.subscriptions add column auto_renew_status boolean;
alter table public.apple_transactions enable row level security;
alter table public.apple_notifications enable row level security;
alter table public.credit_grants enable row level security;
alter table public.credit_allocations enable row level security;
grant select,insert,update on public.apple_transactions,public.apple_notifications,public.credit_grants,public.credit_allocations to service_role;

create or replace function public.reconcile_credit_periods(p_org_id uuid,p_now timestamptz default clock_timestamp())
returns void language plpgsql security definer set search_path='' as $$
declare
  v_grant public.credit_grants%rowtype;
  v_transaction public.apple_transactions%rowtype;
  v_period jsonb;
  v_id uuid;
  v_spent bigint;
  v_amount integer;
  v_balance bigint;
  v_active boolean;
begin
  perform 1 from public.organizations where id=p_org_id for update;
  select exists(select 1 from public.organizations o join public.users u on u.id=o.owner_user_id
    where o.id=p_org_id and u.deleted_at is null) into v_active;
  -- Expiry reverses only UNUSED plan credits. Top-ups have no expires_at.
  for v_grant in select * from public.credit_grants where org_id=p_org_id and expires_at<=p_now
      and expired_amount=0 and reversed_amount=0 for update loop
    select coalesce(sum(amount),0) into v_spent from public.credit_allocations where grant_id=v_grant.id;
    v_amount := greatest(v_grant.amount-v_spent,0);
    if v_amount>0 then
      select coalesce(sum(delta),0)-v_amount into v_balance from public.credit_ledger where org_id=p_org_id;
      insert into public.credit_ledger(org_id,delta,reason,balance_after,original_transaction_id,created_at)
        select p_org_id,-v_amount,'subscription.expiry',v_balance,original_transaction_id,clock_timestamp()
          from public.apple_transactions where transaction_id=v_grant.transaction_id;
      update public.credit_grants set expired_amount=v_amount where id=v_grant.id;
    end if;
  end loop;
  -- A revoked purchase reverses its grant minus amounts already expired.
  -- Previously consumed credits can therefore produce the required negative balance.
  for v_grant in select g.* from public.credit_grants g join public.apple_transactions t using(transaction_id)
      where g.org_id=p_org_id and t.revocation_date is not null and g.reversed_amount=0 for update of g loop
    v_amount := v_grant.amount-v_grant.expired_amount;
    if v_amount>0 then
      select coalesce(sum(delta),0)-v_amount into v_balance from public.credit_ledger where org_id=p_org_id;
      insert into public.credit_ledger(org_id,delta,reason,balance_after,original_transaction_id,created_at)
        select p_org_id,-v_amount,'refund.reversal',v_balance,original_transaction_id,clock_timestamp()
          from public.apple_transactions where transaction_id=v_grant.transaction_id;
      update public.credit_grants set reversed_amount=v_amount where id=v_grant.id;
    end if;
  end loop;
  if not v_active then return; end if;
  for v_transaction in select * from public.apple_transactions where org_id=p_org_id and revocation_date is null loop
    for v_period in select value from jsonb_array_elements(v_transaction.grant_schedule) loop
      if (v_period->>'start')::timestamptz>p_now then continue; end if;
      -- Missed annual months do not accumulate. Only the current month is granted.
      if v_period->>'end' is not null and (v_period->>'end')::timestamptz<=p_now then continue; end if;
      insert into public.credit_grants(org_id,transaction_id,billing_period_start,billing_period_end,kind,amount,expires_at)
        values(p_org_id,v_transaction.transaction_id,(v_period->>'start')::timestamptz,
          (v_period->>'end')::timestamptz,v_period->>'kind',(v_period->>'amount')::integer,
          (v_period->>'end')::timestamptz)
        on conflict do nothing returning id into v_id;
      if v_id is not null then
        select coalesce(sum(delta),0)+(v_period->>'amount')::integer into v_balance from public.credit_ledger where org_id=p_org_id;
        insert into public.credit_ledger(org_id,delta,reason,balance_after,original_transaction_id,created_at)
          values(p_org_id,(v_period->>'amount')::integer,
            case when v_period->>'kind'='topup' then 'topup.purchase' else 'subscription.grant' end,
            v_balance,v_transaction.original_transaction_id,clock_timestamp());
      end if;
      v_id:=null;
    end loop;
  end loop;
end $$;

create or replace function public.apply_verified_apple_transaction(p_org_id uuid,p_transaction jsonb,
  p_notification jsonb default null,p_now timestamptz default clock_timestamp())
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_owner uuid;
  v_existing public.apple_transactions%rowtype;
  v_previous public.subscriptions%rowtype;
  v_latest_purchase timestamptz;
  v_active boolean;
  v_restore boolean;
  v_grant public.credit_grants%rowtype;
  v_balance bigint;
begin
  select o.owner_user_id,u.deleted_at is null into v_owner,v_active from public.organizations o
    join public.users u on u.id=o.owner_user_id where o.id=p_org_id for update of o;
  if v_owner is null or v_owner<>(p_transaction->>'appAccountToken')::uuid then
    raise exception 'Purchase belongs to a different account';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_transaction->>'originalTransactionId',1));
  if exists(select 1 from public.apple_transactions where original_transaction_id=p_transaction->>'originalTransactionId' and org_id<>p_org_id) then
    raise exception 'Subscription belongs to a different account';
  end if;
  select * into v_existing from public.apple_transactions where transaction_id=p_transaction->>'transactionId' for update;
  if found and (v_existing.org_id<>p_org_id or v_existing.product_id<>p_transaction->>'productId') then
    raise exception 'Transaction ownership mismatch';
  end if;
  v_restore := p_notification->>'type'='REFUND_REVERSED'
    and (p_transaction->>'signedDate')::bigint>coalesce(v_existing.signed_date,0);
  if coalesce(v_restore,false) then
    for v_grant in select * from public.credit_grants
        where transaction_id=p_transaction->>'transactionId' and reversed_amount>0 for update loop
      select coalesce(sum(delta),0)+v_grant.reversed_amount into v_balance from public.credit_ledger where org_id=p_org_id;
      insert into public.credit_ledger(org_id,delta,reason,balance_after,original_transaction_id,created_at)
        values(p_org_id,v_grant.reversed_amount,'refund.restored',v_balance,p_transaction->>'originalTransactionId',clock_timestamp());
      update public.credit_grants set reversed_amount=0 where id=v_grant.id;
    end loop;
  end if;
  insert into public.apple_transactions(transaction_id,original_transaction_id,org_id,product_id,app_account_token,
    purchase_date,expires_date,revocation_date,environment,signed_date,tier,grant_schedule,payload_hash)
    values(p_transaction->>'transactionId',p_transaction->>'originalTransactionId',p_org_id,
      p_transaction->>'productId',v_owner,(p_transaction->>'purchaseDate')::timestamptz,
      (p_transaction->>'expiresDate')::timestamptz,(p_transaction->>'revocationDate')::timestamptz,
      p_transaction->>'environment',(p_transaction->>'signedDate')::bigint,p_transaction->>'tier',
      p_transaction->'schedule',p_transaction->>'payloadHash')
    on conflict(transaction_id) do update set
      revocation_date=case when coalesce(v_restore,false) then null
        when excluded.signed_date>=public.apple_transactions.signed_date
          then coalesce(excluded.revocation_date,public.apple_transactions.revocation_date)
        else public.apple_transactions.revocation_date end,
      signed_date=greatest(excluded.signed_date,public.apple_transactions.signed_date);
  if p_transaction->>'tier' is not null then
    select * into v_previous from public.subscriptions where original_transaction_id=p_transaction->>'originalTransactionId' for update;
    select purchase_date into v_latest_purchase from public.apple_transactions where transaction_id=v_previous.latest_transaction_id;
    if v_latest_purchase is null or (p_transaction->>'purchaseDate')::timestamptz>=v_latest_purchase then
      insert into public.subscriptions(original_transaction_id,org_id,product_id,tier,status,expires_at,credits_per_month,
        latest_transaction_id,signed_date,auto_renew_status)
        values(p_transaction->>'originalTransactionId',p_org_id,p_transaction->>'productId',p_transaction->>'tier',
          case when p_transaction->>'revocationDate' is not null then 'revoked'
            when (p_transaction->>'expiresDate')::timestamptz>p_now then 'active' else 'expired' end,
          (p_transaction->>'expiresDate')::timestamptz,(p_transaction->>'creditsPerMonth')::integer,
          p_transaction->>'transactionId',(p_transaction->>'signedDate')::bigint,
          (p_transaction->>'autoRenewStatus')::boolean)
        on conflict(original_transaction_id) do update set product_id=excluded.product_id,tier=excluded.tier,
          status=case when not coalesce(v_restore,false) and public.subscriptions.status='revoked' and public.subscriptions.latest_transaction_id=excluded.latest_transaction_id
            then 'revoked' else excluded.status end,expires_at=excluded.expires_at,
          credits_per_month=excluded.credits_per_month,latest_transaction_id=excluded.latest_transaction_id,
          signed_date=excluded.signed_date,auto_renew_status=coalesce(excluded.auto_renew_status,public.subscriptions.auto_renew_status),updated_at=clock_timestamp()
        where excluded.signed_date>=coalesce(public.subscriptions.signed_date,0);
    end if;
  end if;
  perform public.reconcile_credit_periods(p_org_id,p_now);
  if p_notification is not null then
    insert into public.apple_notifications(notification_uuid,transaction_id,notification_type,subtype,processed_at)
      values(p_notification->>'id',p_transaction->>'transactionId',p_notification->>'type',p_notification->>'subtype',clock_timestamp())
      on conflict do nothing;
  end if;
  return public.credit_balance(p_org_id) || jsonb_build_object('processed',true,'accountActive',v_active);
end $$;

-- Allocations are created in the SAME settlement transaction as assets/debit.
create or replace function public.allocate_generation_credits()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_left integer; v_take integer; v_grant record; v_legacy bigint; v_legacy_spent bigint;
begin
  if new.reason<>'generation.settlement' or new.delta>=0 then return new; end if;
  -- Preserve pre-billing administrative credits; production StoreKit accounts
  -- must always have enough attributed grants for the entire debit.
  if not exists(select 1 from public.apple_transactions where org_id=new.org_id) then return new; end if;
  v_left := -new.delta;
  for v_grant in select g.id,g.amount-g.expired_amount-g.reversed_amount-coalesce(sum(a.amount),0) remaining
      from public.credit_grants g left join public.credit_allocations a on a.grant_id=g.id
      join public.apple_transactions t on t.transaction_id=g.transaction_id
      where g.org_id=new.org_id and t.revocation_date is null and (g.expires_at is null or g.expires_at>clock_timestamp())
      group by g.id order by (g.kind='topup'),g.expires_at nulls last,g.billing_period_start,g.id loop
    v_take := least(v_left,greatest(v_grant.remaining,0));
    if v_take>0 then
      insert into public.credit_allocations(ledger_entry_id,grant_id,amount) values(new.id,v_grant.id,v_take);
      v_left := v_left-v_take;
    end if;
    exit when v_left=0;
  end loop;
  if v_left>0 then
    -- Preserve pre-StoreKit/admin grants without pretending they are Apple purchases.
    select coalesce(sum(delta),0) into v_legacy from public.credit_ledger
      where org_id=new.org_id and original_transaction_id is null and reason<>'generation.settlement';
    select coalesce(sum(-l.delta-coalesce(a.allocated,0)),0) into v_legacy_spent
      from public.credit_ledger l left join (
        select ledger_entry_id,sum(amount) allocated from public.credit_allocations group by ledger_entry_id
      ) a on a.ledger_entry_id=l.id
      where l.org_id=new.org_id and l.reason='generation.settlement' and l.id<>new.id;
    if v_left>greatest(v_legacy-v_legacy_spent,0) then raise exception 'Not enough unexpired credits'; end if;
  end if;
  return new;
end $$;
create trigger allocate_generation_credits after insert on public.credit_ledger
  for each row execute function public.allocate_generation_credits();

revoke all on function public.reconcile_credit_periods(uuid,timestamptz) from public,anon,authenticated;
revoke all on function public.apply_verified_apple_transaction(uuid,jsonb,jsonb,timestamptz) from public,anon,authenticated;
revoke all on function public.allocate_generation_credits() from public,anon,authenticated;
grant execute on function public.reconcile_credit_periods(uuid,timestamptz) to service_role;
grant execute on function public.apply_verified_apple_transaction(uuid,jsonb,jsonb,timestamptz) to service_role;

-- Financial history is append-only, including service-role access.
create or replace function public.prevent_credit_ledger_mutation()
returns trigger language plpgsql set search_path='' as $$
begin raise exception 'Credit history is immutable; append a correcting entry'; end $$;
create trigger immutable_credit_ledger before update or delete on public.credit_ledger
  for each row execute function public.prevent_credit_ledger_mutation();
revoke all on function public.prevent_credit_ledger_mutation() from public,anon,authenticated;
