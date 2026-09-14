-- Approved local migration: reserve first; persist output and debit atomically.
-- Production deployment is a separate action. All writers use the org row lock.
create table public.generation_requests (
  id uuid primary key,
  org_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  input_hash text not null,
  input jsonb not null,
  status text not null check (status in ('running','completed','failed')),
  reserved_credits integer not null check (reserved_credits >= 0),
  lease_token uuid not null,
  lease_expires_at timestamptz not null,
  result jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index generation_requests_active_org_idx on public.generation_requests(org_id, lease_expires_at)
  where status = 'running';
alter table public.generation_requests enable row level security;
grant select, insert, update, delete on public.generation_requests to service_role;

create or replace function public.begin_generation(
  p_request_id uuid, p_org_id uuid, p_product_id uuid,
  p_input_hash text, p_input jsonb, p_quoted_credits integer
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_request public.generation_requests%rowtype;
  v_owner uuid;
  v_balance bigint;
  v_reserved bigint;
  v_lease uuid;
begin
  if p_quoted_credits < 0 or p_quoted_credits is null or p_input_hash is null or p_input is null then
    raise exception 'Invalid reservation';
  end if;
  select owner_user_id into v_owner from public.organizations where id = p_org_id for update;
  if v_owner is null or not exists(select 1 from public.users where id = v_owner and deleted_at is null) then
    return jsonb_build_object('status','unavailable');
  end if;
  -- A UUID collision between two organizations must not overwrite the first
  -- request while both rows are absent from a concurrent initial SELECT.
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
  if not exists(select 1 from public.products where id = p_product_id and org_id = p_org_id
      and coalesce(attributes->>'captureStatus','ready') = 'ready') then
    return jsonb_build_object('status','not_found');
  end if;
  select * into v_request from public.generation_requests where id = p_request_id for update;
  if found then
    if v_request.org_id <> p_org_id or v_request.product_id <> p_product_id or
       v_request.input_hash <> p_input_hash or v_request.input <> p_input then
      return jsonb_build_object('status','conflict');
    end if;
    if v_request.status = 'completed' then
      return jsonb_build_object('status','completed','result',v_request.result);
    end if;
    if v_request.status = 'running' and v_request.lease_expires_at > clock_timestamp() then
      return jsonb_build_object('status','running');
    end if;
  end if;
  select coalesce(sum(delta),0) into v_balance from public.credit_ledger where org_id = p_org_id;
  select coalesce(sum(reserved_credits),0) into v_reserved from public.generation_requests
    where org_id = p_org_id and status = 'running' and lease_expires_at > clock_timestamp()
      and id <> p_request_id;
  if v_balance - v_reserved < p_quoted_credits then
    return jsonb_build_object('status','insufficient','available',v_balance - v_reserved,'required',p_quoted_credits);
  end if;
  v_lease := gen_random_uuid();
  insert into public.generation_requests(id,org_id,product_id,input_hash,input,status,reserved_credits,lease_token,lease_expires_at)
    values(p_request_id,p_org_id,p_product_id,p_input_hash,p_input,'running',p_quoted_credits,v_lease,clock_timestamp()+interval '15 minutes')
    on conflict(id) do update set status='running',reserved_credits=excluded.reserved_credits,
      lease_token=excluded.lease_token,lease_expires_at=excluded.lease_expires_at,result=null,completed_at=null;
  return jsonb_build_object('status','started','leaseToken',v_lease);
end $$;

create or replace function public.complete_generation(
  p_request_id uuid, p_lease_token uuid, p_assets jsonb, p_usages jsonb,
  p_result jsonb, p_credits_to_charge integer
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_request public.generation_requests%rowtype;
  v_org uuid;
  v_owner uuid;
  v_balance bigint;
  v_asset jsonb;
  v_usage jsonb;
  v_asset_id uuid;
  v_assets jsonb := '[]'::jsonb;
  v_result jsonb;
begin
  select org_id into v_org from public.generation_requests where id=p_request_id;
  if v_org is null then raise exception 'Unknown generation request'; end if;
  select owner_user_id into v_owner from public.organizations where id=v_org for update;
  select * into v_request from public.generation_requests where id=p_request_id for update;
  if not found or not exists(select 1 from public.users where id=v_owner and deleted_at is null) then
    raise exception 'Account is unavailable';
  end if;
  if v_request.status='completed' then return v_request.result; end if;
  if v_request.status <> 'running' or v_request.lease_token <> p_lease_token or
      v_request.lease_expires_at <= clock_timestamp() then raise exception 'Generation lease expired'; end if;
  if p_assets is null or p_usages is null or p_result is null or
      p_credits_to_charge is null or p_credits_to_charge < 0 or p_credits_to_charge > v_request.reserved_credits or
      jsonb_typeof(p_assets) <> 'array' or jsonb_typeof(p_usages) <> 'array' or jsonb_typeof(p_result) <> 'object' then
    raise exception 'Invalid settlement';
  end if;
  if p_credits_to_charge > 0 and jsonb_array_length(p_assets)=0 then raise exception 'Cannot charge without output'; end if;
  if coalesce((select sum((item->>'creditsCharged')::integer) from jsonb_array_elements(p_usages) item),0) <> p_credits_to_charge then
    raise exception 'Usage charges do not match settlement';
  end if;
  select coalesce(sum(delta),0) into v_balance from public.credit_ledger where org_id=v_org;
  -- A refund while generation ran can remove funds. Never leave an overdraft
  -- caused by a new debit; the entire result transaction rolls back.
  if v_balance < p_credits_to_charge then raise exception 'Insufficient credits at settlement'; end if;
  for v_asset in select value from jsonb_array_elements(p_assets) loop
    v_asset_id := gen_random_uuid();
    insert into public.assets(id,product_id,type,marketplace,content,validation_status,violations)
      values(v_asset_id,v_request.product_id,v_asset->>'type',v_asset->>'marketplace',v_asset->>'content',
        v_asset->>'status',coalesce(v_asset->'violations','[]'::jsonb));
    v_assets := v_assets || jsonb_build_array(v_asset || jsonb_build_object('id',v_asset_id));
  end loop;
  for v_usage in select value from jsonb_array_elements(p_usages) loop
    insert into public.generations(org_id,provider,model,credits_charged,actual_cost_usd,latency_ms,langfuse_trace_id)
      values(v_org,v_usage->>'provider',v_usage->>'model',(v_usage->>'creditsCharged')::integer,
        (v_usage->>'costUSD')::numeric,(v_usage->>'latencyMs')::integer,v_usage->>'traceId');
  end loop;
  v_balance := v_balance - p_credits_to_charge;
  if p_credits_to_charge > 0 then
    insert into public.credit_ledger(org_id,delta,reason,balance_after,created_at)
      values(v_org,-p_credits_to_charge,'generation.settlement',v_balance,clock_timestamp());
  end if;
  v_result := p_result || jsonb_build_object('assets',v_assets,'creditsCharged',p_credits_to_charge,'balanceAfter',v_balance);
  update public.generation_requests set status='completed',result=v_result,completed_at=clock_timestamp()
    where id=p_request_id;
  return v_result;
end $$;

create or replace function public.fail_generation(p_request_id uuid,p_lease_token uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_org uuid;
begin
  select org_id into v_org from public.generation_requests where id=p_request_id;
  perform 1 from public.organizations where id=v_org for update;
  update public.generation_requests set status='failed',completed_at=clock_timestamp()
    where id=p_request_id and lease_token=p_lease_token and status='running';
end $$;

revoke all on function public.begin_generation(uuid,uuid,uuid,text,jsonb,integer) from public,anon,authenticated;
revoke all on function public.complete_generation(uuid,uuid,jsonb,jsonb,jsonb,integer) from public,anon,authenticated;
revoke all on function public.fail_generation(uuid,uuid) from public,anon,authenticated;
grant execute on function public.begin_generation(uuid,uuid,uuid,text,jsonb,integer) to service_role;
grant execute on function public.complete_generation(uuid,uuid,jsonb,jsonb,jsonb,integer) to service_role;
grant execute on function public.fail_generation(uuid,uuid) to service_role;
grant execute on function public.begin_account_deletion(uuid) to service_role;

-- Sum in one database snapshot: PostgREST's default row cap cannot truncate it.
create or replace function public.credit_balance(p_org_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('balance',coalesce(sum(delta),0),'entryCount',count(*),
    'recordedBalanceAfter',(select balance_after from public.credit_ledger
      where org_id=p_org_id order by created_at desc,id desc limit 1))
  from public.credit_ledger where org_id=p_org_id;
$$;

-- Administrative grants/refunds serialize with settlement too. This is not a
-- StoreKit verifier; only verified billing code may call it for Apple grants.
create or replace function public.append_credit_entry(p_org_id uuid,p_delta integer,p_reason text,p_original_transaction_id text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_balance bigint; v_entry public.credit_ledger%rowtype;
begin
  if p_delta is null or p_delta=0 or p_reason is null then raise exception 'Invalid credit entry'; end if;
  perform 1 from public.organizations where id=p_org_id for update;
  if not found then raise exception 'Workspace is unavailable'; end if;
  select coalesce(sum(delta),0)+p_delta into v_balance from public.credit_ledger where org_id=p_org_id;
  insert into public.credit_ledger(org_id,delta,reason,balance_after,original_transaction_id,created_at)
    values(p_org_id,p_delta,p_reason,v_balance,p_original_transaction_id,clock_timestamp()) returning * into v_entry;
  return to_jsonb(v_entry);
end $$;
revoke all on function public.credit_balance(uuid) from public,anon,authenticated;
revoke all on function public.append_credit_entry(uuid,integer,text,text) from public,anon,authenticated;
grant execute on function public.credit_balance(uuid) to service_role;
grant execute on function public.append_credit_entry(uuid,integer,text,text) to service_role;
