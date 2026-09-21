-- Fixed-window rate limiting, shared across serverless instances.
--
-- The app server is stateless and runs on many instances, so an in-memory
-- limiter would not actually limit anything. This table is the shared counter;
-- `rate_limit_hit` increments the current window atomically and returns the new
-- count, so concurrent requests cannot race past the limit.

create table if not exists rate_limits (
  bucket text not null,
  window_start timestamptz not null,
  count integer not null default 0,
  primary key (bucket, window_start)
);

-- Only the service role touches this table; no end user ever reads it.
alter table rate_limits enable row level security;

-- Atomically count one hit in the current fixed window and return the new total.
create or replace function rate_limit_hit(p_bucket text, p_window_seconds integer)
returns integer
language plpgsql
as $$
declare
  w timestamptz := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  c integer;
begin
  insert into rate_limits (bucket, window_start, count)
  values (p_bucket, w, 1)
  on conflict (bucket, window_start)
  do update set count = rate_limits.count + 1
  returning count into c;
  return c;
end;
$$;

-- Old windows are dead weight. Callers may prune them opportunistically, or a
-- scheduled job can: delete rows whose window is well past any live limit.
create index if not exists rate_limits_window_idx on rate_limits (window_start);
