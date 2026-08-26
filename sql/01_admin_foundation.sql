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
