-- =============================================================================
-- Quantrum admin panel — 2a/4: the front-page reads
-- =============================================================================
-- Paste this WHOLE file into Supabase -> SQL Editor and press Run.
--
-- Split into small files on purpose. The single 47 KB RUN_THIS.sql is easy to
-- truncate on the way to the clipboard, and a truncated paste fails silently:
-- the statements that did arrive succeed and commit, so the editor reports no
-- error while half the dashboard's functions are missing. Each file here is a
-- few KB, self-contained, and ends by printing what it created.
--
-- Safe to re-run. Run them in any order — these only need 01_admin_foundation.sql to have run first.
--
-- Functions in this file:
--   admin_whoami()      am I an admin? the panel's first call
--   admin_overview()    every headline number on the front page
--   admin_timeseries()  daily counts for the charts
-- =============================================================================




-- -----------------------------------------------------------------------------
-- admin_whoami — the panel's first call. "Am I allowed in?"
--
-- Returns a false rather than raising, because the login screen needs to tell
-- a signed-in non-admin why they are being turned away.
-- -----------------------------------------------------------------------------
create or replace function public.admin_whoami()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'is_admin', public.is_admin(),
    'email',    coalesce((select a.email from public.admin_users a where a.user_id = auth.uid()), ''),
    'role',     coalesce((select a.role  from public.admin_users a where a.user_id = auth.uid()), '')
  );
$$;


-- -----------------------------------------------------------------------------
-- admin_overview — every headline number on the front page, in one call
-- -----------------------------------------------------------------------------
create or replace function public.admin_overview(p_include_demo boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_out   jsonb;
begin
  if not public.is_admin() then
    raise exception 'Not authorised.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    -- ---- people -------------------------------------------------------------
    'users_total',      (select count(*) from public.users),
    'users_today',      (select count(*) from public.users u
                          where (u.created_at at time zone 'Asia/Kolkata')::date = v_today),
    'users_7d',         (select count(*) from public.users u
                          where u.created_at >= now() - interval '7 days'),
    'users_30d',        (select count(*) from public.users u
                          where u.created_at >= now() - interval '30 days'),

    -- ---- sign-in activity ---------------------------------------------------
    -- 'signup' counts as a login: the first sign-in is still a sign-in.
    'logins_today',     (select count(*) from public.user_login_events e
                          where e.kind in ('login','signup')
                            and (e.occurred_at at time zone 'Asia/Kolkata')::date = v_today),
    'logins_7d',        (select count(*) from public.user_login_events e
                          where e.kind in ('login','signup') and e.occurred_at >= now() - interval '7 days'),
    'logins_30d',       (select count(*) from public.user_login_events e
                          where e.kind in ('login','signup') and e.occurred_at >= now() - interval '30 days'),

    -- Active = distinct people who signed in. The industry's DAU / WAU / MAU.
    'active_today',     (select count(distinct e.user_id) from public.user_login_events e
                          where e.kind in ('login','signup')
                            and (e.occurred_at at time zone 'Asia/Kolkata')::date = v_today),
    'active_7d',        (select count(distinct e.user_id) from public.user_login_events e
                          where e.kind in ('login','signup') and e.occurred_at >= now() - interval '7 days'),
    'active_30d',       (select count(distinct e.user_id) from public.user_login_events e
                          where e.kind in ('login','signup') and e.occurred_at >= now() - interval '30 days'),
    'last_login_at',    (select max(e.occurred_at) from public.user_login_events e
                          where e.kind in ('login','signup')),

    -- ---- demo funnel --------------------------------------------------------
    'demo_started',     (select count(*) from public.demo_trials),
    'demo_live_now',    (select count(*) from public.demo_trials d where d.expires_at > now()),
    'converted_total',  (select count(*) from public.users u where u.converted_at is not null),
    'paying_users',     (select count(distinct p.user_id) from public.payments p where p.status = 'captured'),
    'testers',          (select count(*) from public.users u where u.is_tester),

    -- ---- challenges ---------------------------------------------------------
    'challenges_total',  (select count(*) from public.challenges c
                           where p_include_demo or not c.is_simulated),
    'challenges_active', (select count(*) from public.challenges c
                           where c.status = 'active' and (p_include_demo or not c.is_simulated)),
    'challenges_passed', (select count(*) from public.challenges c
                           where c.status = 'passed' and (p_include_demo or not c.is_simulated)),
    'challenges_failed', (select count(*) from public.challenges c
                           where c.status = 'failed' and (p_include_demo or not c.is_simulated)),

    -- ---- trading ------------------------------------------------------------
    -- A rejection and a resting order book no money. Only status='FILLED' is
    -- real activity, which is why the counts below separate them.
    'orders_total',     (select count(*) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where p_include_demo or not c.is_simulated),
    'orders_filled',    (select count(*) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where o.status = 'FILLED' and (p_include_demo or not c.is_simulated)),
    'orders_rejected',  (select count(*) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where o.status = 'REJECTED' and (p_include_demo or not c.is_simulated)),
    'orders_today',     (select count(*) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where o.status = 'FILLED'
                           and (o.created_at at time zone 'Asia/Kolkata')::date = v_today
                           and (p_include_demo or not c.is_simulated)),
    'traders_total',    (select count(distinct o.user_id) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where o.status = 'FILLED' and (p_include_demo or not c.is_simulated)),
    'traders_today',    (select count(distinct o.user_id) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where o.status = 'FILLED'
                           and (o.created_at at time zone 'Asia/Kolkata')::date = v_today
                           and (p_include_demo or not c.is_simulated)),

    -- realized_pnl is NULL on entries; sum() skips NULLs, so this is the net
    -- realised P&L across every closing fill. Unrealised is never stored.
    'realized_pnl',     (select coalesce(sum(o.realized_pnl), 0) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where o.status = 'FILLED' and (p_include_demo or not c.is_simulated)),
    'pnl_today',        (select coalesce(sum(o.realized_pnl), 0) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where o.status = 'FILLED'
                           and (o.created_at at time zone 'Asia/Kolkata')::date = v_today
                           and (p_include_demo or not c.is_simulated)),

    -- ---- live exposure, right now -------------------------------------------
    'open_positions',   (select count(*) from public.positions p
                          join public.challenges c on c.id = p.challenge_id
                         where p_include_demo or not c.is_simulated),
    'margin_used',      (select coalesce(sum(p.margin_used), 0) from public.positions p
                          join public.challenges c on c.id = p.challenge_id
                         where p_include_demo or not c.is_simulated),

    -- ---- money in -----------------------------------------------------------
    -- Always real. There is no such thing as a simulated payment.
    'revenue_total',    (select coalesce(sum(p.total_amount), 0) from public.payments p
                         where p.status = 'captured'),
    'revenue_30d',      (select coalesce(sum(p.total_amount), 0) from public.payments p
                         where p.status = 'captured' and p.captured_at >= now() - interval '30 days'),
    'payments_captured',(select count(*) from public.payments p where p.status = 'captured'),
    'payments_failed',  (select count(*) from public.payments p where p.status = 'failed'),

    -- ---- other surfaces -----------------------------------------------------
    'waitlist_total',   (select count(*) from public.waitlist),
    'ai_questions',     (select count(*) from public.ai_question_log),
    'ai_no_match',      (select count(*) from public.ai_question_log l where l.outcome = 'no_match'),

    'generated_at',     now(),
    'includes_demo',    p_include_demo
  ) into v_out;

  return v_out;
end;
$$;

comment on function public.admin_overview(boolean) is
  'Every headline figure for the admin dashboard front page, in one round trip. Excludes demo accounts unless p_include_demo.';


-- -----------------------------------------------------------------------------
-- admin_timeseries — one row per day: signups, logins, active users, fills,
-- realised P&L and revenue. Everything the charts need, in one call.
--
-- Days are IST session dates, not UTC. A 21:00 IST sign-in belongs to that
-- evening, not to tomorrow morning — which is what bucketing on a raw
-- timestamptz would do to an Indian product.
-- -----------------------------------------------------------------------------
create or replace function public.admin_timeseries(
  p_days         integer default 30,
  p_include_demo boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_days    integer := least(greatest(coalesce(p_days, 30), 1), 365);
  v_today   date    := (now() at time zone 'Asia/Kolkata')::date;
  v_from    date    := v_today - (v_days - 1);
  v_from_ts timestamptz := (v_from::timestamp at time zone 'Asia/Kolkata');
  v_out     jsonb;
begin
  if not public.is_admin() then
    raise exception 'Not authorised.' using errcode = '42501';
  end if;

  with days as (
    select generate_series(v_from, v_today, interval '1 day')::date as day
  ),
  signups as (
    select (e.occurred_at at time zone 'Asia/Kolkata')::date as day, count(*) as n
      from public.user_login_events e
     where e.kind = 'signup' and e.occurred_at >= v_from_ts
     group by 1
  ),
  logins as (
    select (e.occurred_at at time zone 'Asia/Kolkata')::date as day,
           count(*)                  as n,
           count(distinct e.user_id) as users
      from public.user_login_events e
     where e.kind in ('login','signup') and e.occurred_at >= v_from_ts
     group by 1
  ),
  fills as (
    select (o.created_at at time zone 'Asia/Kolkata')::date as day,
           count(*)                          as n,
           count(distinct o.user_id)         as traders,
           coalesce(sum(o.realized_pnl), 0)  as pnl
      from public.orders o
      join public.challenges c on c.id = o.challenge_id
     where o.status = 'FILLED'
       and o.created_at >= v_from_ts
       and (p_include_demo or not c.is_simulated)
     group by 1
  ),
  rejects as (
    select (o.created_at at time zone 'Asia/Kolkata')::date as day, count(*) as n
      from public.orders o
      join public.challenges c on c.id = o.challenge_id
     where o.status = 'REJECTED'
       and o.created_at >= v_from_ts
       and (p_include_demo or not c.is_simulated)
     group by 1
  ),
  revenue as (
    select (p.captured_at at time zone 'Asia/Kolkata')::date as day,
           coalesce(sum(p.total_amount), 0) as amount
      from public.payments p
     where p.status = 'captured' and p.captured_at >= v_from_ts
     group by 1
  )
  select jsonb_agg(
           jsonb_build_object(
             'day',          d.day,
             'signups',      coalesce(s.n, 0),
             'logins',       coalesce(l.n, 0),
             'active_users', coalesce(l.users, 0),
             'fills',        coalesce(f.n, 0),
             'traders',      coalesce(f.traders, 0),
             'realized_pnl', coalesce(f.pnl, 0),
             'rejections',   coalesce(r.n, 0),
             'revenue',      coalesce(v.amount, 0)
           ) order by d.day
         )
    into v_out
    from days d
    left join signups s on s.day = d.day
    left join logins  l on l.day = d.day
    left join fills   f on f.day = d.day
    left join rejects r on r.day = d.day
    left join revenue v on v.day = d.day;

  return coalesce(v_out, '[]'::jsonb);
end;
$$;

comment on function public.admin_timeseries(integer, boolean) is
  'Daily counts for the dashboard charts, bucketed on IST session dates. Days with no activity are present as zeroes, so a chart never draws a gap where a quiet day was.';


-- -----------------------------------------------------------------------------
-- admin_users_list — the people table: who they are, when they last signed in,
-- and what they have done. Search, sort and paginate.
-- -----------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- GRANTS. CREATE FUNCTION grants EXECUTE to PUBLIC by default, which would
-- hand these to `anon` — the key that ships in the browser bundle. Revoke
-- first, then grant to `authenticated` only.
-- ---------------------------------------------------------------------------
revoke all on function public.is_admin()                           from public;
revoke all on function public.admin_whoami()                       from public;
revoke all on function public.admin_overview(boolean)              from public;
revoke all on function public.admin_timeseries(integer, boolean)   from public;

grant execute on function public.is_admin()                           to authenticated;
grant execute on function public.admin_whoami()                       to authenticated;
grant execute on function public.admin_overview(boolean)              to authenticated;
grant execute on function public.admin_timeseries(integer, boolean)   to authenticated;

-- What this file created:
select p.proname as function, pg_catalog.pg_get_function_identity_arguments(p.oid) as arguments
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('is_admin', 'admin_whoami', 'admin_overview', 'admin_timeseries')
 order by 1;
