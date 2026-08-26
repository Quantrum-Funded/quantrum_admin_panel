-- =============================================================================
-- Quantrum admin panel — WHY IS EVERY TRADING NUMBER ZERO?
-- =============================================================================
-- Read-only. Changes nothing. Safe to run on production.
--
-- Run this in Supabase -> SQL Editor when the Trading tiles all say 0 but you
-- know people have been placing orders.
--
-- ONE statement on purpose. The SQL Editor only renders the result of the LAST
-- statement in a script, so a file of six separate SELECTs shows you one table
-- and silently drops the other five — which is how a diagnostic ends up being
-- the thing that needs diagnosing. Everything below is a single UNION ALL and
-- comes back as one table you can read top to bottom.
--
-- The first row is the verdict. The rest is the evidence behind it.
-- =============================================================================

with
-- Raw counts. No demo filter, no join, no date window — this is "what is in
-- the tables", against which every filtered number can be compared.
raw as (
  select
    (select count(*) from public.users)                                as users,
    (select count(*) from public.challenges)                           as challenges,
    (select count(*) from public.challenges c where not c.is_simulated) as ch_live,
    (select count(*) from public.challenges c where c.is_simulated)     as ch_demo,
    (select count(*) from public.orders)                               as orders,
    (select count(*) from public.orders o where o.status = 'FILLED')   as fills,
    (select count(*) from public.orders o where o.status = 'REJECTED') as rejects,
    (select count(*) from public.positions)                            as positions,
    (select count(*) from public.payments)                             as payments,
    (select count(*) from public.payments p where p.status = 'captured') as paid
),

-- THE DECISIVE ONE. Every trading figure on the dashboard runs through
--     join challenges c on c.id = o.challenge_id
--     where (p_include_demo or not c.is_simulated)
-- so a fill only counts if the challenge behind it is a LIVE one. This splits
-- the fills the same way the dashboard does.
split as (
  select
    count(*) filter (where not c.is_simulated)                         as fills_live,
    count(*) filter (where c.is_simulated)                             as fills_demo,
    coalesce(sum(o.realized_pnl) filter (where not c.is_simulated), 0) as pnl_live,
    coalesce(sum(o.realized_pnl) filter (where c.is_simulated), 0)     as pnl_demo
  from public.orders o
  join public.challenges c on c.id = o.challenge_id
  where o.status = 'FILLED'
),

-- An INNER join drops silently. If challenge_id were ever null or dangling,
-- the order would vanish from every tile with no error anywhere — and turning
-- the demo toggle on would NOT bring it back. Worth ruling out explicitly.
orphans as (
  select count(*) as n
    from public.orders o
    left join public.challenges c on c.id = o.challenge_id
   where c.id is null
),

-- "Today" on the dashboard is an IST session date, not a UTC one. If the only
-- fills are from yesterday IST, the today-tiles are correctly zero while the
-- all-time tiles are not.
today as (
  select
    ((now() at time zone 'Asia/Kolkata')::date)                 as ist_today,
    (select max(o.created_at) from public.orders o)             as last_order_at,
    (select count(*) from public.orders o
      where o.status = 'FILLED'
        and (o.created_at at time zone 'Asia/Kolkata')::date
            = ((now() at time zone 'Asia/Kolkata')::date))      as fills_today
)

-- ---- the verdict ------------------------------------------------------------
select 1 as n, '① VERDICT' as section, 'why every trading tile reads 0' as detail,
       case
         when r.orders = 0 then
           'public.orders is EMPTY. Nothing has placed an order yet, or the app '
           || 'writing them (app_record_trade) is not deployed. Not a dashboard bug.'
         when o.n = r.orders then
           'ALL ' || r.orders || ' orders point at a challenge_id that does not exist. '
           || 'The dashboard''s inner join drops every one. The demo toggle will NOT help.'
         when s.fills_live = 0 and s.fills_demo > 0 then
           'NOT A BUG. All ' || s.fills_demo || ' fills belong to DEMO/tester challenges '
           || '(is_simulated = true), and the panel excludes demo by default. '
           || 'Tick "Include demo accounts" in the header and the numbers appear.'
         when r.fills = 0 and r.orders > 0 then
           r.orders || ' orders exist but NONE are status = ''FILLED'' — only fills count '
           || 'as trading. See the status mix below.'
         when s.fills_live > 0 then
           'There ARE ' || s.fills_live || ' live fills, so the data is not the problem. '
           || 'Re-run 00_check.sql — a missing or ungranted admin_* function is the next suspect.'
         else 'Inconclusive — read the evidence rows below.'
       end as value
  from raw r, split s, orphans o

union all select 2, '② RAW COUNTS', 'users',                        r.users::text          from raw r
union all select 3, '② RAW COUNTS', 'orders (any status)',          r.orders::text         from raw r
union all select 4, '② RAW COUNTS', 'orders FILLED',                r.fills::text          from raw r
union all select 5, '② RAW COUNTS', 'orders REJECTED',              r.rejects::text        from raw r
union all select 6, '② RAW COUNTS', 'open positions',               r.positions::text      from raw r

union all select 7, '③ THE DEMO SPLIT', 'challenges — LIVE (counted by default)',  r.ch_live::text from raw r
union all select 8, '③ THE DEMO SPLIT', 'challenges — demo (hidden by default)',   r.ch_demo::text from raw r
union all select 9, '③ THE DEMO SPLIT', 'fills — LIVE (what the tiles show)',      s.fills_live::text from split s
union all select 10,'③ THE DEMO SPLIT', 'fills — demo (hidden until you tick the box)', s.fills_demo::text from split s
union all select 11,'③ THE DEMO SPLIT', 'realised P&L — LIVE',   '₹ ' || round(s.pnl_live)::text  from split s
union all select 12,'③ THE DEMO SPLIT', 'realised P&L — demo',   '₹ ' || round(s.pnl_demo)::text  from split s

union all select 13,'④ ORPHANS', 'orders whose challenge is missing',
       case when o.n = 0 then '0 — good, the join drops nothing'
            else o.n::text || ' — these vanish from every tile, toggle or not' end
  from orphans o

union all select 14,'⑤ PAYMENTS', 'payments — captured (this is Revenue)',
       r.paid::text || case when r.paid = 0
         then ' — revenue is genuinely ₹0. Note: the demo toggle does NOT affect revenue.'
         else '' end
  from raw r
union all select 15,'⑤ PAYMENTS', 'payments — any status', r.payments::text from raw r

union all select 16,'⑥ TODAY (IST)', 'IST session date the panel is using', t.ist_today::text from today t
union all select 17,'⑥ TODAY (IST)', 'most recent order, any status',
       coalesce(t.last_order_at::text, 'never') from today t
union all select 18,'⑥ TODAY (IST)', 'fills today, before the demo filter',
       t.fills_today::text || case when t.fills_today = 0
         then ' — so the "today" tiles are correctly 0 even if all-time is not' else '' end
  from today t

order by n;


-- =============================================================================
-- THE ORDER STATUS MIX, if the verdict pointed you at it.
-- Uncomment, select these three lines only, and Run.
-- =============================================================================
-- select o.status, c.is_simulated, count(*) as orders
--   from public.orders o
--   left join public.challenges c on c.id = o.challenge_id
--  group by o.status, c.is_simulated order by orders desc;
