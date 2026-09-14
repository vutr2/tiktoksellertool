-- Correct paid-credit catch-up without changing tables or rewriting ledger history.
-- Existing purchases recover missing periods on their next billing reconciliation.
-- Future periods remain scheduled; subscription feature access is unchanged.

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
  -- Expiry reverses only UNUSED credits that carry an expiry date. Since
  -- migration 0005 that is the free trial alone; paid credits carry none.
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
      -- Every started paid period remains owed, even after the subscription ends.
      -- The unique grant key makes catch-up safe on replay and concurrent refresh.
      -- Only an expired free trial must not be granted retroactively.
      if v_period->>'kind'='trial' and v_period->>'end' is not null
          and (v_period->>'end')::timestamptz<=p_now then continue; end if;
      -- Only the free trial expires. Credits that were paid for, plan
      -- allowances and top-ups alike, carry no expiry date so nothing can take
      -- them back. billing_period_end is still recorded: it schedules the next
      -- month's grant, it no longer ends the credits.
      insert into public.credit_grants(org_id,transaction_id,billing_period_start,billing_period_end,kind,amount,expires_at)
        values(p_org_id,v_transaction.transaction_id,(v_period->>'start')::timestamptz,
          (v_period->>'end')::timestamptz,v_period->>'kind',(v_period->>'amount')::integer,
          case when v_period->>'kind'='trial' then (v_period->>'end')::timestamptz end)
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
