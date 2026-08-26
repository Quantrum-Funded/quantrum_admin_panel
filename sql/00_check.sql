-- =============================================================================
-- Quantrum admin panel — CHECK: what is actually installed?
-- =============================================================================
-- Run this in the Supabase SQL Editor any time the dashboard says something is
-- missing. It changes nothing. Each section prints a verdict, so you can see
-- exactly which file still needs running rather than guessing.
-- =============================================================================

-- 1. The two tables from 01_admin_foundation.sql -----------------------------
select 'TABLES' as section,
       t.name,
       case when c.oid is null then '❌ MISSING — run 01_admin_foundation.sql'
            else '✅ present' end as status
  from (values ('admin_users'), ('user_login_events')) as t(name)
  left join pg_catalog.pg_class c
         on c.relname = t.name
        and c.relnamespace = 'public'::regnamespace
        and c.relkind = 'r'
 order by t.name;

-- 2. The trigger that captures sign-ins ---------------------------------------
select 'TRIGGER' as section,
       'users_record_activity' as name,
       case when count(*) = 0 then '❌ MISSING — run 01_admin_foundation.sql'
            else '✅ present — sign-ins are being recorded' end as status
  from pg_catalog.pg_trigger
 where tgname = 'users_record_activity' and not tgisinternal;

-- 3. Every function the dashboard calls ---------------------------------------
--    This is the one that tells you where a truncated paste stopped.
select 'FUNCTION' as section,
       f.name,
       case when p.oid is null then '❌ MISSING — run ' || f.file
            else '✅ present' end as status
  from (values
          ('is_admin',              '01_admin_foundation.sql'),
          ('admin_whoami',          '02a_read_core.sql'),
          ('admin_overview',        '02a_read_core.sql'),
          ('admin_timeseries',      '02a_read_core.sql'),
          ('admin_recent_activity', '02b_activity.sql'),
          ('admin_trading_summary', '02c_trading.sql'),
          ('admin_funnel',          '02c_trading.sql')
       ) as f(name, file)
  left join pg_catalog.pg_proc p
         on p.proname = f.name
        and p.pronamespace = 'public'::regnamespace
 order by f.file, f.name;

-- 4. Can `authenticated` actually call them? ----------------------------------
--    A function that exists but was never granted fails with "permission
--    denied", which looks nothing like "missing" — worth checking separately.
select 'GRANT' as section,
       p.proname as name,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
            then '✅ authenticated may call it'
            else '❌ not granted — re-run the file that creates it' end as status
  from pg_catalog.pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and (p.proname like 'admin\_%' or p.proname = 'is_admin')
 order by p.proname;

-- 5. Who is on the admin allow-list? ------------------------------------------
--    Empty here means every sign-in gets "not on the admin allow-list", even
--    though the setup is otherwise complete.
select 'ADMINS' as section, a.email, a.role, a.created_at
  from public.admin_users a
 order by a.created_at;

-- 6. How much history is there to show? ---------------------------------------
select 'DATA' as section, 'users'             as name, count(*)::text as value from public.users
union all
select 'DATA', 'login events recorded',  count(*)::text from public.user_login_events
union all
select 'DATA', 'sign-ins (login+signup)', count(*)::text from public.user_login_events
                                                          where kind in ('login','signup')
union all
select 'DATA', 'orders',                 count(*)::text from public.orders
union all
select 'DATA', 'challenges',             count(*)::text from public.challenges;
