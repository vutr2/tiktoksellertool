-- Account deletion lock (SPEC §5.3).
--
-- `account-deletion.ts` calls this before it starts removing data. The function
-- was referenced by the code but never written, so every deletion attempt
-- failed with "Could not start account deletion" — and in-app deletion is
-- mandatory for App Store review.
--
-- Adds no tables and no columns. It only wraps two existing facts in one
-- transaction:
--
--   1. Locking the account's workspaces, so a generation cannot settle credits
--      against a workspace that is being deleted.
--   2. Tombstoning the user, which makes `verifyAccount` reject every further
--      request while the slower cleanup (photos, products, generations) runs.
--
-- Tombstoning first is deliberate: a failure part-way through leaves an account
-- that can retry, not a live account whose data is half gone.

create or replace function begin_account_deletion(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_found boolean;
begin
  -- Serialises against concurrent credit settlement for the same workspaces.
  perform 1
    from organizations
   where owner_user_id = p_user_id
   order by id
   for update;

  -- coalesce keeps the original timestamp when the app retries a deletion whose
  -- first response was lost, so the audit trail records one deletion, not two.
  update users
     set deleted_at = coalesce(deleted_at, now())
   where id = p_user_id
  returning true into v_found;

  if v_found is null then
    raise exception 'Account % does not exist', p_user_id
      using errcode = 'no_data_found';
  end if;
end;
$$;

-- Only the server may run this; it is never reachable from a client key.
revoke all on function begin_account_deletion(uuid) from public;
revoke all on function begin_account_deletion(uuid) from anon;
revoke all on function begin_account_deletion(uuid) from authenticated;
grant execute on function begin_account_deletion(uuid) to service_role;
