-- ============================================================================
-- RUN THIS — everything, in one paste.  (26 Aug 2026)
--
-- ⚠️  ~40 KB. A paste that long can be silently truncated on the way into the
--     SQL editor, and a truncated paste FAILS SILENTLY: the statements that
--     did arrive succeed and commit, so the editor reports no error while
--     half the functions are missing.
--
--     Prefer the small files — a few KB each, safe to re-run, each prints
--     what it created:
--
--       01_admin_foundation.sql   tables, trigger, backfill
--       02a_read_core.sql         Overview
--       02b_activity.sql          the sign-in feed
--       02c_trading.sql           Trading + Funnel
--       04_user_filter.sql        the user filter in the header
--
--     00_check.sql reports which of the above are already installed.
-- ============================================================================


-- =============================================================================
-- Quantrum admin panel — 1/2: who may read, and where "login times" come from
--
-- RUN THIS FIRST, then 02_admin_rpcs.sql.
-- Supabase dashboard -> SQL Editor -> paste -> Run. Safe to re-run.
--
-- This file adds ONLY new objects. It does not alter a single existing table,
-- function or policy. The one thing it attaches to something that already
-- exists is an AFTER trigger on public.users — additive, and explained in
-- part 2 below.
--
-- Two problems to solve before a dashboard can exist:
--
--   1. WHO IS ALLOWED TO LOOK. The app's identity is Firebase, and the schema
--      revokes `anon` from every table on purpose, so the anon key on its own
--      reads nothing. Good — that key ships inside the admin panel's JS bundle.
--      The admin team therefore gets its OWN Supabase Auth login, completely
--      separate from the trader accounts, and every read below is gated on it.
--
--   2. LOGIN TIMES DO NOT EXIST YET. `users` carries created_at and
--      updated_at and nothing else; `user_sessions` was specified but never
--      given a writer. Part 2 fixes that without touching the app.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- PART 1 — the admin allow-list
--
-- A Supabase Auth user is not an admin because they exist. They are an admin
-- because a row here says so. Adding a teammate is one INSERT; removing them is
-- one DELETE, and it takes effect on their next request.
-- -----------------------------------------------------------------------------
create table if not exists public.admin_users (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  email      text not null default '',
  role       text not null default 'viewer' check (role in ('viewer', 'owner')),
  note       text not null default '',
  created_at timestamptz not null default now()
);

comment on table public.admin_users is
  'Allow-list for the internal admin dashboard. A Supabase Auth account with no row here can call none of the admin_* functions. Unrelated to public.users, which is the Firebase-identified traders.';

alter table public.admin_users enable row level security;

-- No policy is added on purpose. RLS with zero policies denies everyone, and
-- nothing needs to read this table directly — admin_whoami() answers "am I an
-- admin?" through a security-definer function instead. The allow-list is
-- managed from the SQL editor with the service role.


-- The gate every admin_* function opens with.
--
-- security definer so it can read admin_users past that deny-all RLS; stable so
-- one query calls it once rather than per row.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.admin_users a where a.user_id = auth.uid()
  );
$$;

comment on function public.is_admin() is
  'True when the caller''s Supabase Auth uid is on the admin allow-list. Returns false — never raises — for anon, so an unauthenticated caller simply sees nothing.';


-- -----------------------------------------------------------------------------
-- PART 2 — login history, captured without touching the app
--
-- THE TRICK, AND WHY IT IS SOUND.
--
-- Signing in already writes to Postgres. POST /api/auth/session runs on every
-- sign-in, hands the Firebase ID token to the Worker, and the Worker calls
-- app_ensure_user — whose INSERT ... ON CONFLICT (id) DO UPDATE touches the
-- row every single time, which the existing users_touch trigger turns into a
-- fresh updated_at.
--
-- So public.users is ALREADY receiving one write per login. It just throws the
-- history away by overwriting a timestamp. An AFTER trigger keeps it instead.
--
-- That means: no change to app_ensure_user, no change to the Worker, no change
-- to any route. Nothing to deploy on the app side at all. Run this file and
-- logins start being recorded on the next sign-in.
--
-- The cost is that public.users is written by a few things that are NOT logins
-- (buying a challenge, starting the demo, saving a notification toggle), so the
-- trigger classifies rather than assuming. Every one of those non-login writes
-- changes a specific column, and a plain sign-in changes none of them — which
-- makes the classification exact, not a guess.
-- -----------------------------------------------------------------------------
create table if not exists public.user_login_events (
  id            uuid primary key default gen_random_uuid(),
  user_id       text not null references public.users (id) on delete cascade,

  -- What the write actually was. 'login' is the sign-in touch; the rest are
  -- lifecycle moments worth seeing on the same timeline.
  kind          text not null default 'login' check (kind in (
                  'signup',        -- the very first sign-in: row created
                  'login',         -- app_ensure_user touched the row again
                  'demo_start',    -- demo_trial_started_at stamped
                  'converted',     -- converted_at stamped: they paid
                  'account_type',  -- trial <-> live
                  'tester',        -- tester allow-list applied
                  'settings')),    -- notification toggles saved

  -- Snapshotted, not joined: an account that later switches provider must not
  -- rewrite how it signed in last March.
  auth_provider text not null default '',
  email         text not null default '',
  occurred_at   timestamptz not null default now()
);

comment on table public.user_login_events is
  'One row per write to public.users, classified. Gives the admin dashboard sign-in history and last-seen, which the schema otherwise discards by overwriting users.updated_at. Written by a trigger — no application code calls it.';

comment on column public.user_login_events.kind is
  'login = a sign-in (app_ensure_user re-touched the row). signup = first ever sign-in. The rest are lifecycle stamps that also write public.users.';

create index if not exists user_login_events_occurred_idx
  on public.user_login_events (occurred_at desc);

create index if not exists user_login_events_user_idx
  on public.user_login_events (user_id, occurred_at desc);

-- Answers "how many distinct people signed in this week" without reading the
-- lifecycle rows.
create index if not exists user_login_events_kind_idx
  on public.user_login_events (kind, occurred_at desc);

alter table public.user_login_events enable row level security;
-- Deny-all again: the admin_* functions are security definer and read it on
-- the caller's behalf. Nobody queries this table directly.


create or replace function public.record_user_activity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text;
begin
  if tg_op = 'INSERT' then
    v_kind := 'signup';
  else
    -- Order matters: check the specific stamps first and let a plain sign-in
    -- fall through to the bottom. Reversing this would label a conversion as a
    -- login, because a conversion also re-touches the row.
    if old.demo_trial_started_at is null and new.demo_trial_started_at is not null then
      v_kind := 'demo_start';
    elsif old.converted_at is null and new.converted_at is not null then
      v_kind := 'converted';
    elsif old.is_tester is distinct from new.is_tester then
      v_kind := 'tester';
    elsif old.account_type is distinct from new.account_type then
      v_kind := 'account_type';
    elsif old.notify_rule_warnings is distinct from new.notify_rule_warnings
       or old.notify_challenge_end  is distinct from new.notify_challenge_end
       or old.notify_payouts        is distinct from new.notify_payouts then
      v_kind := 'settings';
    else
      -- Nothing meaningful changed, yet the row was written. That is
      -- app_ensure_user re-upserting the same values — i.e. somebody signed in.
      v_kind := 'login';
    end if;
  end if;

  insert into public.user_login_events (user_id, kind, auth_provider, email)
  values (new.id, v_kind, coalesce(new.auth_provider, ''), coalesce(new.email, ''));

  return null;  -- AFTER trigger: the return value is ignored.
exception
  -- A dashboard must never be the reason a sign-in fails. If this insert
  -- breaks for any reason, swallow it and let the user through.
  when others then
    return null;
end;
$$;

comment on function public.record_user_activity() is
  'AFTER trigger on public.users. Turns each write into a classified activity row so login history survives. Deliberately swallows its own errors: analytics must never block a sign-in.';

drop trigger if exists users_record_activity on public.users;

create trigger users_record_activity
  after insert or update on public.users
  for each row execute function public.record_user_activity();


-- -----------------------------------------------------------------------------
-- PART 3 — backfill, so the dashboard is not empty on day one
--
-- Everyone who already exists gets a 'signup' at their created_at, plus one
-- 'login' at their updated_at when that is meaningfully later. That is the
-- entire history the old schema retained; it cannot be reconstructed further
-- back, and the dashboard labels these as estimates rather than pretending.
--
-- Guarded on the table being empty, so re-running this file is harmless.
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from public.user_login_events) then

    insert into public.user_login_events (user_id, kind, auth_provider, email, occurred_at)
    select u.id, 'signup', coalesce(u.auth_provider, ''), coalesce(u.email, ''), u.created_at
      from public.users u;

    insert into public.user_login_events (user_id, kind, auth_provider, email, occurred_at)
    select u.id, 'login', coalesce(u.auth_provider, ''), coalesce(u.email, ''), u.updated_at
      from public.users u
     where u.updated_at > u.created_at + interval '1 minute';

    raise notice 'Backfilled activity for % existing users.', (select count(*) from public.users);
  end if;
end;
$$;


-- -----------------------------------------------------------------------------
-- PART 4 — make yourself an admin
--
-- 1. Supabase dashboard -> Authentication -> Users -> "Add user"
--    Create one with an email + password, and TICK "Auto Confirm User".
--    Do this for each person on the ops team.
--
-- 2. Run this, with their address:
--
--      insert into public.admin_users (user_id, email, role)
--      select id, email, 'owner' from auth.users where email = 'you@quantrum.in'
--      on conflict (user_id) do nothing;
--
-- 3. Check it took:
--
--      select a.email, a.role from public.admin_users a;
--
-- To revoke someone:  delete from public.admin_users where email = '...';
-- -----------------------------------------------------------------------------


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


-- =============================================================================
-- Quantrum admin panel — 2b/3: the sign-in feed
-- =============================================================================
-- Paste this WHOLE file into Supabase -> SQL Editor and press Run.
-- Safe to re-run. Needs 01_admin_foundation.sql to have run first.
--
-- Functions in this file:
--   admin_recent_activity()  the sign-in feed, used by Overview and Logins
--
-- The Users page was dropped from the dashboard, and with it
-- admin_users_list() and admin_user_detail(). If an earlier attempt created
-- either of those, the cleanup at the bottom of this file removes them — they
-- are no longer called by anything.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- admin_recent_activity — the live feed: who just signed in, and from where
-- -----------------------------------------------------------------------------
create or replace function public.admin_recent_activity(p_limit integer default 40)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 40), 1), 200);
  v_out   jsonb;
begin
  if not public.is_admin() then
    raise exception 'Not authorised.' using errcode = '42501';
  end if;

  select jsonb_agg(jsonb_build_object(
           'user_id',      e.user_id,
           'email',        coalesce(nullif(e.email, ''), u.email, ''),
           'name',         coalesce(u.name, ''),
           'kind',         e.kind,
           'provider',     e.auth_provider,
           'account_type', coalesce(u.account_type, ''),
           'is_tester',    coalesce(u.is_tester, false),
           'country',      coalesce(u.country_code, ''),
           'at',           e.occurred_at
         ) order by e.occurred_at desc)
    into v_out
    from (
      select * from public.user_login_events e2
       order by e2.occurred_at desc limit v_limit
    ) e
    left join public.users u on u.id = e.user_id;

  return coalesce(v_out, '[]'::jsonb);
end;
$$;


-- ---------------------------------------------------------------------------
-- GRANTS. CREATE FUNCTION grants EXECUTE to PUBLIC by default, which would
-- hand this to `anon` — the key that ships in the browser bundle. Revoke
-- first, then grant to `authenticated` only.
-- ---------------------------------------------------------------------------
revoke all on function public.admin_recent_activity(integer)  from public;
grant execute on function public.admin_recent_activity(integer) to authenticated;


-- ---------------------------------------------------------------------------
-- Cleanup: the Users page is gone, so these two are dead. `if exists` so this
-- is a no-op on a database where they were never created.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_users_list(text, integer, integer, text, boolean);
drop function if exists public.admin_user_detail(text);


-- What this file created:
select p.proname as function,
       pg_catalog.pg_get_function_identity_arguments(p.oid) as arguments
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'admin_recent_activity'
 order by 1;


-- =============================================================================
-- Quantrum admin panel — 2c/4: the Trading and Funnel pages
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
--   admin_trading_summary() top traders, symbols, rejections, positions
--   admin_funnel()          signed up -> came back -> traded -> paid
-- =============================================================================


create or replace function public.admin_trading_summary(
  p_limit        integer default 10,
  p_include_demo boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 10), 1), 100);
  v_out   jsonb;
begin
  if not public.is_admin() then
    raise exception 'Not authorised.' using errcode = '42501';
  end if;

  select jsonb_build_object(

    -- Win rate is per CLOSING ORDER, not per round trip. `trades` — the table
    -- that would pair an entry to its exit — has no writer yet, so a true
    -- round-trip win rate is not derivable today. Labelled as such in the UI.
    'top_traders', coalesce((
      select jsonb_agg(row_to_json(t)::jsonb order by t.realized_pnl desc)
        from (
          select o.user_id,
                 coalesce(u.email, '') as email,
                 coalesce(u.name, '')  as name,
                 count(*)                                          as fills,
                 count(*) filter (where o.realized_pnl is not null) as closing_orders,
                 count(*) filter (where o.realized_pnl > 0)         as wins,
                 round(100.0 * count(*) filter (where o.realized_pnl > 0)
                       / nullif(count(*) filter (where o.realized_pnl is not null), 0), 1)
                                                                   as win_rate_pct,
                 coalesce(sum(o.realized_pnl), 0)                  as realized_pnl
            from public.orders o
            join public.challenges c on c.id = o.challenge_id
            left join public.users u on u.id = o.user_id
           where o.status = 'FILLED' and (p_include_demo or not c.is_simulated)
           group by o.user_id, u.email, u.name
           order by realized_pnl desc
           limit v_limit
        ) t
    ), '[]'::jsonb),

    'symbols', coalesce((
      select jsonb_agg(row_to_json(s)::jsonb order by s.fills desc)
        from (
          select o.symbol, o.instrument,
                 count(*)                         as fills,
                 coalesce(sum(o.lots), 0)         as lots,
                 coalesce(sum(o.qty), 0)          as contracts,
                 coalesce(sum(o.realized_pnl), 0) as realized_pnl
            from public.orders o
            join public.challenges c on c.id = o.challenge_id
           where o.status = 'FILLED' and (p_include_demo or not c.is_simulated)
           group by o.symbol, o.instrument
           order by fills desc
           limit v_limit
        ) s
    ), '[]'::jsonb),

    -- Where the rule engine bites. Each reason is the engine's own sentence.
    'rejections', coalesce((
      select jsonb_agg(row_to_json(r)::jsonb order by r.count desc)
        from (
          select o.reject_reason as reason, count(*) as count
            from public.orders o
            join public.challenges c on c.id = o.challenge_id
           where o.status = 'REJECTED' and (p_include_demo or not c.is_simulated)
           group by o.reject_reason
           order by count desc
           limit v_limit
        ) r
    ), '[]'::jsonb),

    'recent_orders', coalesce((
      select jsonb_agg(row_to_json(ro)::jsonb order by ro.created_at desc)
        from (
          select o.id, o.symbol, o.instrument, o.side, o.order_type,
                 o.lots, o.qty, o.status, o.reject_reason, o.fill_price,
                 o.realized_pnl, o.source, o.created_at,
                 c.is_simulated, coalesce(u.email, '') as email
            from public.orders o
            join public.challenges c on c.id = o.challenge_id
            left join public.users u on u.id = o.user_id
           where p_include_demo or not c.is_simulated
           order by o.created_at desc
           limit 40
        ) ro
    ), '[]'::jsonb),

    'open_positions', coalesce((
      select jsonb_agg(row_to_json(op)::jsonb order by op.margin_used desc)
        from (
          select p.symbol, p.instrument, p.side, p.lots, p.qty,
                 p.entry_price, p.margin_used, p.opened_at,
                 coalesce(u.email, '') as email, c.is_simulated
            from public.positions p
            join public.challenges c on c.id = p.challenge_id
            left join public.users u on u.id = p.user_id
           where p_include_demo or not c.is_simulated
           order by p.margin_used desc
           limit 50
        ) op
    ), '[]'::jsonb),

    -- Order status mix, for the donut.
    'status_mix', coalesce((
      select jsonb_agg(jsonb_build_object('status', m.status, 'count', m.count))
        from (
          select o.status, count(*) as count
            from public.orders o
            join public.challenges c on c.id = o.challenge_id
           where p_include_demo or not c.is_simulated
           group by o.status
        ) m
    ), '[]'::jsonb)

  ) into v_out;

  return v_out;
end;
$$;


-- -----------------------------------------------------------------------------
-- admin_funnel — signed up -> signed in again -> started demo -> placed an
-- order -> paid. The one chart a non-technical team actually asks for.
-- -----------------------------------------------------------------------------
create or replace function public.admin_funnel()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_out jsonb;
begin
  if not public.is_admin() then
    raise exception 'Not authorised.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'signed_up',   count(*),
    'returned',    count(*) filter (where act.logins > 1),
    'started_demo',count(*) filter (where u.demo_trial_started_at is not null),
    'placed_order',count(*) filter (where od.fills > 0),
    'paid',        count(*) filter (where u.converted_at is not null),

    -- Providers and geography, for the same page.
    'by_provider', (
      select coalesce(jsonb_agg(jsonb_build_object('provider',
               case when coalesce(p.auth_provider,'') = '' then 'unknown' else p.auth_provider end,
               'count', p.count) order by p.count desc), '[]'::jsonb)
        from (select u2.auth_provider, count(*) as count
                from public.users u2 group by u2.auth_provider) p
    ),
    'by_country', (
      select coalesce(jsonb_agg(jsonb_build_object('country',
               case when coalesce(g.country_code,'') = '' then 'unknown' else g.country_code end,
               'count', g.count) order by g.count desc), '[]'::jsonb)
        from (select u3.country_code, count(*) as count
                from public.users u3 group by u3.country_code) g
    ),
    'by_account_type', (
      select coalesce(jsonb_agg(jsonb_build_object('account_type', t.account_type, 'count', t.count)
               order by t.count desc), '[]'::jsonb)
        from (select u4.account_type, count(*) as count
                from public.users u4 group by u4.account_type) t
    )
  ) into v_out
  from public.users u
  left join lateral (
    select count(*) as logins from public.user_login_events e
     where e.user_id = u.id and e.kind in ('login','signup')
  ) act on true
  left join lateral (
    select count(*) as fills
      from public.orders o
      join public.challenges c on c.id = o.challenge_id
     where o.user_id = u.id and o.status = 'FILLED' and not c.is_simulated
  ) od on true;

  return v_out;
end;
$$;


-- ---------------------------------------------------------------------------
-- GRANTS. CREATE FUNCTION grants EXECUTE to PUBLIC by default, which would
-- hand these to `anon` — the key that ships in the browser bundle. Revoke
-- first, then grant to `authenticated` only.
-- ---------------------------------------------------------------------------
revoke all on function public.admin_trading_summary(integer, boolean)   from public;
revoke all on function public.admin_funnel()                            from public;

grant execute on function public.admin_trading_summary(integer, boolean)   to authenticated;
grant execute on function public.admin_funnel()                            to authenticated;

-- What this file created:
select p.proname as function, pg_catalog.pg_get_function_identity_arguments(p.oid) as arguments
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('admin_trading_summary', 'admin_funnel')
 order by 1;


-- =============================================================================
-- Quantrum admin panel — 04/4: filter the whole dashboard to ONE person
-- =============================================================================
-- Paste this WHOLE file into Supabase -> SQL Editor and press Run.
-- Safe to re-run. Needs 01, 02a, 02b and 02c to have run first.
--
-- WHY THIS EXISTS
--
-- Every number on the panel is a platform total. That answers "how are we
-- doing", and it is no help at all with the question the ops team actually
-- gets asked: "what happened with THIS person?" Today that means scrolling the
-- activity log with a finger on the screen and hoping nobody asks a follow-up.
--
-- This adds one more global filter — a user — next to the demo toggle and the
-- 7d/30d/90d window. Pick somebody and every tile, chart and table on all four
-- pages narrows to them. With nobody picked, every function returns exactly
-- what it returned before.
--
-- HOW IT IS DONE
--
-- Each read function gains one argument, `p_user_id text default null`, and
-- every aggregate inside it gains `(v_uid is null or <table>.user_id = v_uid)`.
-- Null means "everyone", which is the old behaviour — so the panel that is
-- already deployed keeps working against these the moment they land, and the
-- new build can go out whenever it suits.
--
-- Postgres cannot add an argument to a function in place, so the five existing
-- ones are dropped and recreated. They are recreated in this same file, and
-- the SQL editor runs a script in one transaction — so the dashboard is never
-- actually left without them, not even for a moment.
--
-- Functions in this file:
--   admin_user_search()      the people the picker offers  (new)
--   admin_overview()         + p_user_id
--   admin_timeseries()       + p_user_id
--   admin_recent_activity()  + p_user_id
--   admin_trading_summary()  + p_user_id
--   admin_funnel()           + p_user_id
-- =============================================================================


-- -----------------------------------------------------------------------------
-- PREFLIGHT — runs before anything is dropped
--
-- Filtering by a person means every table read below has to be able to say
-- which person a row belongs to. Most of those columns the dashboard already
-- uses; two of them — challenges.user_id and demo_trials.user_id — it never
-- has, so this file is the first thing to name them.
--
-- If one is missing, stop here rather than half-way. The drops further down
-- have not run yet, so an abort leaves the dashboard exactly as it was. Send
-- whoever gave you this file the message it raises; the fix is one line.
-- -----------------------------------------------------------------------------
do $$
declare
  v_missing text[] := '{}';
  r         record;
begin
  for r in
    select * from (values
      ('users',             'id'),
      ('user_login_events', 'user_id'),
      ('orders',            'user_id'),
      ('positions',         'user_id'),
      ('payments',          'user_id'),
      ('challenges',        'user_id'),
      ('demo_trials',       'user_id')
    ) as t(tbl, col)
  loop
    if not exists (
      select 1 from information_schema.columns c
       where c.table_schema = 'public'
         and c.table_name   = r.tbl
         and c.column_name  = r.col
    ) then
      v_missing := v_missing || (r.tbl || '.' || r.col);
    end if;
  end loop;

  if array_length(v_missing, 1) > 0 then
    raise exception
      'Cannot install the user filter — % does not exist. NOTHING WAS CHANGED; the dashboard is untouched. Send this exact message to whoever gave you this file.',
      array_to_string(v_missing, ', ');
  end if;

  raise notice 'Preflight OK — every table can say which user a row belongs to.';
end;
$$;


-- -----------------------------------------------------------------------------
-- admin_user_search — what the picker in the header offers
--
-- Typing filters on email, name or id. Typing nothing lists the most recently
-- active people, which is what somebody opening the picker almost always
-- wants: the person they are being asked about signed in five minutes ago.
--
-- The shortlist is taken FIRST and the per-person counts computed only on it.
-- The other way round — counting logins and fills for every user and then
-- keeping twenty — is the version that gets slow the month the product works.
--
-- users.updated_at is the sort key rather than a join, because app_ensure_user
-- re-touches that column on every single sign-in (see 01_admin_foundation.sql).
-- It is already last-seen; it just was not being kept as history.
-- -----------------------------------------------------------------------------
create or replace function public.admin_user_search(
  p_q     text    default '',
  p_limit integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_q     text    := nullif(trim(coalesce(p_q, '')), '');
  v_out   jsonb;
begin
  if not public.is_admin() then
    raise exception 'Not authorised.' using errcode = '42501';
  end if;

  with picked as (
    select u.id, u.email, u.name, u.account_type, u.is_tester,
           u.country_code, u.auth_provider, u.created_at,
           u.demo_trial_started_at, u.converted_at
      from public.users u
     where v_q is null
        or u.email ilike '%' || v_q || '%'
        or u.name  ilike '%' || v_q || '%'
        or u.id    ilike '%' || v_q || '%'
     order by u.updated_at desc nulls last
     limit v_limit
  )
  select jsonb_agg(jsonb_build_object(
           'user_id',         p.id,
           'email',           coalesce(p.email, ''),
           'name',            coalesce(p.name, ''),
           'account_type',    coalesce(p.account_type, ''),
           'is_tester',       coalesce(p.is_tester, false),
           'country',         coalesce(p.country_code, ''),
           'provider',        coalesce(p.auth_provider, ''),
           'created_at',      p.created_at,
           'demo_started_at', p.demo_trial_started_at,
           'converted_at',    p.converted_at,
           'last_seen',       act.last_seen,
           'logins',          coalesce(act.logins, 0),
           'fills',           coalesce(tr.fills, 0),
           'realized_pnl',    coalesce(tr.pnl, 0)
         ) order by act.last_seen desc nulls last)
    into v_out
    from picked p
    left join lateral (
      select max(e.occurred_at)                                   as last_seen,
             count(*) filter (where e.kind in ('login','signup')) as logins
        from public.user_login_events e
       where e.user_id = p.id
    ) act on true
    left join lateral (
      select count(*)                        as fills,
             coalesce(sum(o.realized_pnl),0) as pnl
        from public.orders o
       where o.user_id = p.id and o.status = 'FILLED'
    ) tr on true;

  return coalesce(v_out, '[]'::jsonb);
end;
$$;

comment on function public.admin_user_search(text, integer) is
  'Feeds the user picker in the admin header. Blank query lists the most recently active people. Returns enough per person (last seen, sign-ins, fills, P&L) that the header strip needs no second call.';


-- =============================================================================
-- The five existing reads, re-cut so they can be pointed at one person.
--
-- `drop` then `create`, because an argument cannot be added in place. Each one
-- is identical to the version in 02a/02b/02c except for v_uid.
-- =============================================================================
drop function if exists public.admin_overview(boolean);
drop function if exists public.admin_timeseries(integer, boolean);
drop function if exists public.admin_recent_activity(integer);
drop function if exists public.admin_trading_summary(integer, boolean);
drop function if exists public.admin_funnel();


-- -----------------------------------------------------------------------------
-- admin_overview — every headline number, optionally for one person
--
-- Two figures go null rather than wrong when a person is picked:
--
--   waitlist_total — the waitlist is people who have NOT signed up yet. It has
--     no user to be filtered by, and quietly showing the platform total next
--     to five personal ones is how a screenshot ends up in the wrong meeting.
--   ai_questions / ai_no_match — same reasoning; the log is not read per user
--     anywhere in this dashboard, so it is left alone rather than guessed at.
--
-- The panel hides those tiles when they come back null.
-- -----------------------------------------------------------------------------
create or replace function public.admin_overview(
  p_include_demo boolean default false,
  p_user_id      text    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  -- One place decides what "no filter" means, so an empty string from a URL or
  -- a cleared box can never be mistaken for a user whose id happens to be ''.
  v_uid   text := nullif(trim(coalesce(p_user_id, '')), '');
  v_out   jsonb;
begin
  if not public.is_admin() then
    raise exception 'Not authorised.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    -- ---- people -------------------------------------------------------------
    'users_total',      (select count(*) from public.users u
                          where v_uid is null or u.id = v_uid),
    'users_today',      (select count(*) from public.users u
                          where (u.created_at at time zone 'Asia/Kolkata')::date = v_today
                            and (v_uid is null or u.id = v_uid)),
    'users_7d',         (select count(*) from public.users u
                          where u.created_at >= now() - interval '7 days'
                            and (v_uid is null or u.id = v_uid)),
    'users_30d',        (select count(*) from public.users u
                          where u.created_at >= now() - interval '30 days'
                            and (v_uid is null or u.id = v_uid)),

    -- ---- sign-in activity ---------------------------------------------------
    -- 'signup' counts as a login: the first sign-in is still a sign-in.
    'logins_today',     (select count(*) from public.user_login_events e
                          where e.kind in ('login','signup')
                            and (e.occurred_at at time zone 'Asia/Kolkata')::date = v_today
                            and (v_uid is null or e.user_id = v_uid)),
    'logins_7d',        (select count(*) from public.user_login_events e
                          where e.kind in ('login','signup') and e.occurred_at >= now() - interval '7 days'
                            and (v_uid is null or e.user_id = v_uid)),
    'logins_30d',       (select count(*) from public.user_login_events e
                          where e.kind in ('login','signup') and e.occurred_at >= now() - interval '30 days'
                            and (v_uid is null or e.user_id = v_uid)),

    -- Active = distinct people who signed in. The industry's DAU / WAU / MAU.
    -- Filtered to one person it can only be 0 or 1, which is exactly the
    -- honest answer to "was he on today?" — the panel relabels the tile rather
    -- than pretending the number means something bigger.
    'active_today',     (select count(distinct e.user_id) from public.user_login_events e
                          where e.kind in ('login','signup')
                            and (e.occurred_at at time zone 'Asia/Kolkata')::date = v_today
                            and (v_uid is null or e.user_id = v_uid)),
    'active_7d',        (select count(distinct e.user_id) from public.user_login_events e
                          where e.kind in ('login','signup') and e.occurred_at >= now() - interval '7 days'
                            and (v_uid is null or e.user_id = v_uid)),
    'active_30d',       (select count(distinct e.user_id) from public.user_login_events e
                          where e.kind in ('login','signup') and e.occurred_at >= now() - interval '30 days'
                            and (v_uid is null or e.user_id = v_uid)),
    'last_login_at',    (select max(e.occurred_at) from public.user_login_events e
                          where e.kind in ('login','signup')
                            and (v_uid is null or e.user_id = v_uid)),

    -- ---- demo funnel --------------------------------------------------------
    'demo_started',     (select count(*) from public.demo_trials d
                          where v_uid is null or d.user_id = v_uid),
    'demo_live_now',    (select count(*) from public.demo_trials d
                          where d.expires_at > now()
                            and (v_uid is null or d.user_id = v_uid)),
    'converted_total',  (select count(*) from public.users u where u.converted_at is not null
                            and (v_uid is null or u.id = v_uid)),
    'paying_users',     (select count(distinct p.user_id) from public.payments p
                          where p.status = 'captured'
                            and (v_uid is null or p.user_id = v_uid)),
    'testers',          (select count(*) from public.users u where u.is_tester
                            and (v_uid is null or u.id = v_uid)),

    -- ---- challenges ---------------------------------------------------------
    'challenges_total',  (select count(*) from public.challenges c
                           where (p_include_demo or not c.is_simulated)
                             and (v_uid is null or c.user_id = v_uid)),
    'challenges_active', (select count(*) from public.challenges c
                           where c.status = 'active' and (p_include_demo or not c.is_simulated)
                             and (v_uid is null or c.user_id = v_uid)),
    'challenges_passed', (select count(*) from public.challenges c
                           where c.status = 'passed' and (p_include_demo or not c.is_simulated)
                             and (v_uid is null or c.user_id = v_uid)),
    'challenges_failed', (select count(*) from public.challenges c
                           where c.status = 'failed' and (p_include_demo or not c.is_simulated)
                             and (v_uid is null or c.user_id = v_uid)),

    -- ---- trading ------------------------------------------------------------
    -- A rejection and a resting order book no money. Only status='FILLED' is
    -- real activity, which is why the counts below separate them.
    --
    -- The filter is on orders.user_id, not challenges.user_id: they are the
    -- same person today, and the order is the row that actually happened.
    'orders_total',     (select count(*) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where (p_include_demo or not c.is_simulated)
                           and (v_uid is null or o.user_id = v_uid)),
    'orders_filled',    (select count(*) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where o.status = 'FILLED' and (p_include_demo or not c.is_simulated)
                           and (v_uid is null or o.user_id = v_uid)),
    'orders_rejected',  (select count(*) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where o.status = 'REJECTED' and (p_include_demo or not c.is_simulated)
                           and (v_uid is null or o.user_id = v_uid)),
    'orders_today',     (select count(*) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where o.status = 'FILLED'
                           and (o.created_at at time zone 'Asia/Kolkata')::date = v_today
                           and (p_include_demo or not c.is_simulated)
                           and (v_uid is null or o.user_id = v_uid)),
    'traders_total',    (select count(distinct o.user_id) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where o.status = 'FILLED' and (p_include_demo or not c.is_simulated)
                           and (v_uid is null or o.user_id = v_uid)),
    'traders_today',    (select count(distinct o.user_id) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where o.status = 'FILLED'
                           and (o.created_at at time zone 'Asia/Kolkata')::date = v_today
                           and (p_include_demo or not c.is_simulated)
                           and (v_uid is null or o.user_id = v_uid)),

    -- realized_pnl is NULL on entries; sum() skips NULLs, so this is the net
    -- realised P&L across every closing fill. Unrealised is never stored.
    'realized_pnl',     (select coalesce(sum(o.realized_pnl), 0) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where o.status = 'FILLED' and (p_include_demo or not c.is_simulated)
                           and (v_uid is null or o.user_id = v_uid)),
    'pnl_today',        (select coalesce(sum(o.realized_pnl), 0) from public.orders o
                          join public.challenges c on c.id = o.challenge_id
                         where o.status = 'FILLED'
                           and (o.created_at at time zone 'Asia/Kolkata')::date = v_today
                           and (p_include_demo or not c.is_simulated)
                           and (v_uid is null or o.user_id = v_uid)),

    -- ---- live exposure, right now -------------------------------------------
    'open_positions',   (select count(*) from public.positions ps
                          join public.challenges c on c.id = ps.challenge_id
                         where (p_include_demo or not c.is_simulated)
                           and (v_uid is null or ps.user_id = v_uid)),
    'margin_used',      (select coalesce(sum(ps.margin_used), 0) from public.positions ps
                          join public.challenges c on c.id = ps.challenge_id
                         where (p_include_demo or not c.is_simulated)
                           and (v_uid is null or ps.user_id = v_uid)),

    -- ---- money in -----------------------------------------------------------
    -- Always real. There is no such thing as a simulated payment.
    'revenue_total',    (select coalesce(sum(p.total_amount), 0) from public.payments p
                         where p.status = 'captured'
                           and (v_uid is null or p.user_id = v_uid)),
    'revenue_30d',      (select coalesce(sum(p.total_amount), 0) from public.payments p
                         where p.status = 'captured' and p.captured_at >= now() - interval '30 days'
                           and (v_uid is null or p.user_id = v_uid)),
    'payments_captured',(select count(*) from public.payments p where p.status = 'captured'
                           and (v_uid is null or p.user_id = v_uid)),
    'payments_failed',  (select count(*) from public.payments p where p.status = 'failed'
                           and (v_uid is null or p.user_id = v_uid)),

    -- ---- other surfaces -----------------------------------------------------
    -- Null, not zero, and not the platform total, when one person is picked.
    -- See the note above the function.
    'waitlist_total',   (case when v_uid is null
                              then (select count(*) from public.waitlist) end),
    'ai_questions',     (case when v_uid is null
                              then (select count(*) from public.ai_question_log) end),
    'ai_no_match',      (case when v_uid is null
                              then (select count(*) from public.ai_question_log l
                                     where l.outcome = 'no_match') end),

    'generated_at',     now(),
    'includes_demo',    p_include_demo,
    'user_id',          v_uid
  ) into v_out;

  return v_out;
end;
$$;

comment on function public.admin_overview(boolean, text) is
  'Every headline figure for the admin dashboard front page, in one round trip. Excludes demo accounts unless p_include_demo. p_user_id null = the whole platform; set it to narrow every figure to one person.';


-- -----------------------------------------------------------------------------
-- admin_timeseries — one row per day, optionally for one person
--
-- Days are IST session dates, not UTC. A 21:00 IST sign-in belongs to that
-- evening, not to tomorrow morning — which is what bucketing on a raw
-- timestamptz would do to an Indian product.
--
-- Quiet days still come back, as zeroes. That matters much more once a filter
-- is on: one person's chart is mostly quiet days, and a line that skipped them
-- would draw a busy week out of four scattered sessions.
-- -----------------------------------------------------------------------------
create or replace function public.admin_timeseries(
  p_days         integer default 30,
  p_include_demo boolean default false,
  p_user_id      text    default null
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
  v_uid     text    := nullif(trim(coalesce(p_user_id, '')), '');
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
       and (v_uid is null or e.user_id = v_uid)
     group by 1
  ),
  logins as (
    select (e.occurred_at at time zone 'Asia/Kolkata')::date as day,
           count(*)                  as n,
           count(distinct e.user_id) as users
      from public.user_login_events e
     where e.kind in ('login','signup') and e.occurred_at >= v_from_ts
       and (v_uid is null or e.user_id = v_uid)
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
       and (v_uid is null or o.user_id = v_uid)
     group by 1
  ),
  rejects as (
    select (o.created_at at time zone 'Asia/Kolkata')::date as day, count(*) as n
      from public.orders o
      join public.challenges c on c.id = o.challenge_id
     where o.status = 'REJECTED'
       and o.created_at >= v_from_ts
       and (p_include_demo or not c.is_simulated)
       and (v_uid is null or o.user_id = v_uid)
     group by 1
  ),
  revenue as (
    select (p.captured_at at time zone 'Asia/Kolkata')::date as day,
           coalesce(sum(p.total_amount), 0) as amount
      from public.payments p
     where p.status = 'captured' and p.captured_at >= v_from_ts
       and (v_uid is null or p.user_id = v_uid)
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

comment on function public.admin_timeseries(integer, boolean, text) is
  'Daily counts for the dashboard charts, bucketed on IST session dates. Days with no activity are present as zeroes, so a chart never draws a gap where a quiet day was. p_user_id null = the whole platform.';


-- -----------------------------------------------------------------------------
-- admin_recent_activity — the feed: who signed in, and from where
--
-- With a user picked this becomes that person's timeline, and it is the reason
-- the whole filter is worth having: signed up, came back, started the demo,
-- paid, changed a setting — in order, in one column, with nothing else in it.
--
-- The limit is applied INSIDE the filter, not after it. Taking the newest 40
-- rows and then keeping this person's would show four events and imply that
-- was all they ever did.
-- -----------------------------------------------------------------------------
create or replace function public.admin_recent_activity(
  p_limit   integer default 40,
  p_user_id text    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 40), 1), 200);
  v_uid   text    := nullif(trim(coalesce(p_user_id, '')), '');
  v_out   jsonb;
begin
  if not public.is_admin() then
    raise exception 'Not authorised.' using errcode = '42501';
  end if;

  select jsonb_agg(jsonb_build_object(
           'user_id',      e.user_id,
           'email',        coalesce(nullif(e.email, ''), u.email, ''),
           'name',         coalesce(u.name, ''),
           'kind',         e.kind,
           'provider',     e.auth_provider,
           'account_type', coalesce(u.account_type, ''),
           'is_tester',    coalesce(u.is_tester, false),
           'country',      coalesce(u.country_code, ''),
           'at',           e.occurred_at
         ) order by e.occurred_at desc)
    into v_out
    from (
      select * from public.user_login_events e2
       where v_uid is null or e2.user_id = v_uid
       order by e2.occurred_at desc limit v_limit
    ) e
    left join public.users u on u.id = e.user_id;

  return coalesce(v_out, '[]'::jsonb);
end;
$$;

comment on function public.admin_recent_activity(integer, text) is
  'The sign-in and lifecycle feed, newest first. p_user_id null = everybody; set it and this becomes one person''s timeline.';


-- -----------------------------------------------------------------------------
-- admin_trading_summary — top traders, symbols, rejections, positions, orders
--
-- With a user picked, "top traders" is a table of one — which is the point.
-- It is that person's fills, closes, win rate and P&L on the same row shape
-- everyone already reads, so nobody has to learn a second layout to answer a
-- question about one account.
-- -----------------------------------------------------------------------------
create or replace function public.admin_trading_summary(
  p_limit        integer default 10,
  p_include_demo boolean default false,
  p_user_id      text    default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 10), 1), 100);
  v_uid   text    := nullif(trim(coalesce(p_user_id, '')), '');
  v_out   jsonb;
begin
  if not public.is_admin() then
    raise exception 'Not authorised.' using errcode = '42501';
  end if;

  select jsonb_build_object(

    -- Win rate is per CLOSING ORDER, not per round trip. `trades` — the table
    -- that would pair an entry to its exit — has no writer yet, so a true
    -- round-trip win rate is not derivable today. Labelled as such in the UI.
    'top_traders', coalesce((
      select jsonb_agg(row_to_json(t)::jsonb order by t.realized_pnl desc)
        from (
          select o.user_id,
                 coalesce(u.email, '') as email,
                 coalesce(u.name, '')  as name,
                 count(*)                                          as fills,
                 count(*) filter (where o.realized_pnl is not null) as closing_orders,
                 count(*) filter (where o.realized_pnl > 0)         as wins,
                 round(100.0 * count(*) filter (where o.realized_pnl > 0)
                       / nullif(count(*) filter (where o.realized_pnl is not null), 0), 1)
                                                                   as win_rate_pct,
                 coalesce(sum(o.realized_pnl), 0)                  as realized_pnl
            from public.orders o
            join public.challenges c on c.id = o.challenge_id
            left join public.users u on u.id = o.user_id
           where o.status = 'FILLED' and (p_include_demo or not c.is_simulated)
             and (v_uid is null or o.user_id = v_uid)
           group by o.user_id, u.email, u.name
           order by realized_pnl desc
           limit v_limit
        ) t
    ), '[]'::jsonb),

    'symbols', coalesce((
      select jsonb_agg(row_to_json(s)::jsonb order by s.fills desc)
        from (
          select o.symbol, o.instrument,
                 count(*)                         as fills,
                 coalesce(sum(o.lots), 0)         as lots,
                 coalesce(sum(o.qty), 0)          as contracts,
                 coalesce(sum(o.realized_pnl), 0) as realized_pnl
            from public.orders o
            join public.challenges c on c.id = o.challenge_id
           where o.status = 'FILLED' and (p_include_demo or not c.is_simulated)
             and (v_uid is null or o.user_id = v_uid)
           group by o.symbol, o.instrument
           order by fills desc
           limit v_limit
        ) s
    ), '[]'::jsonb),

    -- Where the rule engine bites. Each reason is the engine's own sentence.
    -- Per person this is the single most useful table on the page: "why do my
    -- orders keep getting refused" has an answer, in the engine's words.
    'rejections', coalesce((
      select jsonb_agg(row_to_json(r)::jsonb order by r.count desc)
        from (
          select o.reject_reason as reason, count(*) as count
            from public.orders o
            join public.challenges c on c.id = o.challenge_id
           where o.status = 'REJECTED' and (p_include_demo or not c.is_simulated)
             and (v_uid is null or o.user_id = v_uid)
           group by o.reject_reason
           order by count desc
           limit v_limit
        ) r
    ), '[]'::jsonb),

    'recent_orders', coalesce((
      select jsonb_agg(row_to_json(ro)::jsonb order by ro.created_at desc)
        from (
          select o.id, o.symbol, o.instrument, o.side, o.order_type,
                 o.lots, o.qty, o.status, o.reject_reason, o.fill_price,
                 o.realized_pnl, o.source, o.created_at,
                 c.is_simulated, coalesce(u.email, '') as email
            from public.orders o
            join public.challenges c on c.id = o.challenge_id
            left join public.users u on u.id = o.user_id
           where (p_include_demo or not c.is_simulated)
             and (v_uid is null or o.user_id = v_uid)
           order by o.created_at desc
           limit 40
        ) ro
    ), '[]'::jsonb),

    'open_positions', coalesce((
      select jsonb_agg(row_to_json(op)::jsonb order by op.margin_used desc)
        from (
          select ps.symbol, ps.instrument, ps.side, ps.lots, ps.qty,
                 ps.entry_price, ps.margin_used, ps.opened_at,
                 coalesce(u.email, '') as email, c.is_simulated
            from public.positions ps
            join public.challenges c on c.id = ps.challenge_id
            left join public.users u on u.id = ps.user_id
           where (p_include_demo or not c.is_simulated)
             and (v_uid is null or ps.user_id = v_uid)
           order by ps.margin_used desc
           limit 50
        ) op
    ), '[]'::jsonb),

    -- Order status mix, for the donut.
    'status_mix', coalesce((
      select jsonb_agg(jsonb_build_object('status', m.status, 'count', m.count))
        from (
          select o.status, count(*) as count
            from public.orders o
            join public.challenges c on c.id = o.challenge_id
           where (p_include_demo or not c.is_simulated)
             and (v_uid is null or o.user_id = v_uid)
           group by o.status
        ) m
    ), '[]'::jsonb)

  ) into v_out;

  return v_out;
end;
$$;

comment on function public.admin_trading_summary(integer, boolean, text) is
  'Trading page in one round trip: top traders, symbols, rejection reasons, open positions, latest orders, status mix. p_user_id null = the whole platform.';


-- -----------------------------------------------------------------------------
-- admin_funnel — signed up -> came back -> started demo -> traded -> paid
--
-- Pointed at one person this stops being a funnel and becomes a five-line
-- biography: which of those five things they did, and — much more usefully —
-- the first one they did not. That is the answer to "what happened with this
-- guy", and it fits on a phone screenshot.
--
-- The provider / country / account-type splits collapse to one slice each,
-- which is correct: they say how THIS person signed in and where from.
-- -----------------------------------------------------------------------------
create or replace function public.admin_funnel(p_user_id text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid text := nullif(trim(coalesce(p_user_id, '')), '');
  v_out jsonb;
begin
  if not public.is_admin() then
    raise exception 'Not authorised.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'signed_up',   count(*),
    'returned',    count(*) filter (where act.logins > 1),
    'started_demo',count(*) filter (where u.demo_trial_started_at is not null),
    'placed_order',count(*) filter (where od.fills > 0),
    'paid',        count(*) filter (where u.converted_at is not null),

    -- Providers and geography, for the same page.
    'by_provider', (
      select coalesce(jsonb_agg(jsonb_build_object('provider',
               case when coalesce(p.auth_provider,'') = '' then 'unknown' else p.auth_provider end,
               'count', p.count) order by p.count desc), '[]'::jsonb)
        from (select u2.auth_provider, count(*) as count
                from public.users u2
               where v_uid is null or u2.id = v_uid
               group by u2.auth_provider) p
    ),
    'by_country', (
      select coalesce(jsonb_agg(jsonb_build_object('country',
               case when coalesce(g.country_code,'') = '' then 'unknown' else g.country_code end,
               'count', g.count) order by g.count desc), '[]'::jsonb)
        from (select u3.country_code, count(*) as count
                from public.users u3
               where v_uid is null or u3.id = v_uid
               group by u3.country_code) g
    ),
    'by_account_type', (
      select coalesce(jsonb_agg(jsonb_build_object('account_type', t.account_type, 'count', t.count)
               order by t.count desc), '[]'::jsonb)
        from (select u4.account_type, count(*) as count
                from public.users u4
               where v_uid is null or u4.id = v_uid
               group by u4.account_type) t
    ),
    'user_id', v_uid
  ) into v_out
  from public.users u
  left join lateral (
    select count(*) as logins from public.user_login_events e
     where e.user_id = u.id and e.kind in ('login','signup')
  ) act on true
  left join lateral (
    select count(*) as fills
      from public.orders o
      join public.challenges c on c.id = o.challenge_id
     where o.user_id = u.id and o.status = 'FILLED' and not c.is_simulated
  ) od on true
  where v_uid is null or u.id = v_uid;

  return v_out;
end;
$$;

comment on function public.admin_funnel(text) is
  'Signup funnel: signed up -> came back -> started demo -> placed a live trade -> paid. p_user_id null = everybody; set it and each step is a yes/no for that person.';


-- ---------------------------------------------------------------------------
-- GRANTS. CREATE FUNCTION grants EXECUTE to PUBLIC by default, which would
-- hand these to `anon` — the key that ships in the browser bundle. Revoke
-- first, then grant to `authenticated` only.
--
-- Every signature here is NEW (the argument list changed), so the grants from
-- 02a/02b/02c do not carry over. Forgetting this block is how the dashboard
-- ends up saying "permission denied" for a function that plainly exists.
-- ---------------------------------------------------------------------------
revoke all on function public.admin_user_search(text, integer)                 from public;
revoke all on function public.admin_overview(boolean, text)                    from public;
revoke all on function public.admin_timeseries(integer, boolean, text)         from public;
revoke all on function public.admin_recent_activity(integer, text)             from public;
revoke all on function public.admin_trading_summary(integer, boolean, text)    from public;
revoke all on function public.admin_funnel(text)                               from public;

grant execute on function public.admin_user_search(text, integer)              to authenticated;
grant execute on function public.admin_overview(boolean, text)                 to authenticated;
grant execute on function public.admin_timeseries(integer, boolean, text)      to authenticated;
grant execute on function public.admin_recent_activity(integer, text)          to authenticated;
grant execute on function public.admin_trading_summary(integer, boolean, text) to authenticated;
grant execute on function public.admin_funnel(text)                            to authenticated;


-- PostgREST answers from a cached copy of the schema, and it is the argument
-- names in that cache that decide which overload a call resolves to. Supabase
-- refreshes it on DDL by itself; this nudge makes the new signatures visible
-- immediately rather than after a pause that looks exactly like "the SQL did
-- not run". Harmless if nothing is listening.
notify pgrst, 'reload schema';


-- What this file created, and whether the panel may call it:
select 'FUNCTION' as section,
       p.proname  as name,
       pg_catalog.pg_get_function_identity_arguments(p.oid) as detail,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
            then '✅ ready'
            else '❌ not granted — re-run this file' end as status
  from pg_catalog.pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('admin_user_search', 'admin_overview', 'admin_timeseries',
                     'admin_recent_activity', 'admin_trading_summary', 'admin_funnel')
 order by p.proname;
