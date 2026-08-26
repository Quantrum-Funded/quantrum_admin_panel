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
