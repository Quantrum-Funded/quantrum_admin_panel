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
