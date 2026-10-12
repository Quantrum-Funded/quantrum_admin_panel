-- Run once in the Supabase SQL Editor after the existing admin setup.
-- Only allow-listed admins can read these waitlist contact details.
create or replace function public.admin_waitlist_leads(
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id uuid,
  created_at timestamptz,
  name text,
  email text,
  phone text,
  interest_category text,
  interest_tier text,
  would_pay_fee boolean,
  traded_fno boolean,
  tried_funded boolean,
  demo_easy_nav boolean,
  demo_feels_live boolean,
  demo_would_pay boolean,
  source text,
  note text,
  lead_score integer,
  account_type text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;

  return query
  select
    w.id, w.created_at, w.name, w.email, w.phone,
    w.interest_category, w.interest_tier, w.would_pay_fee,
    w.traded_fno, w.tried_funded, w.demo_easy_nav,
    w.demo_feels_live, w.demo_would_pay, w.source, w.note,
    ((w.would_pay_fee is true)::integer * 4
      + (w.traded_fno is true)::integer * 2
      + (w.interest_tier <> '')::integer) as lead_score,
    u.account_type::text
  from public.waitlist as w
  left join public.users as u on u.id = w.user_id
  order by w.created_at desc, w.id desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

revoke all on function public.admin_waitlist_leads(integer, integer) from public, anon;
grant execute on function public.admin_waitlist_leads(integer, integer) to authenticated;
