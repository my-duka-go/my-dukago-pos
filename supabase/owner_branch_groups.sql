-- Phase 2: owner multi-branch view (build 194). ADDITIVE ONLY.
-- Every existing shop has group_id NULL, so current behaviour, RLS and sync are unchanged until the
-- platform admin groups two shops. The Owner dashboard (a new "Branches" tab, Admin-only) reads a
-- cross-branch summary from the owner-summary edge function; owner_group_summary() does the aggregation.

alter table public.shops add column if not exists group_id   uuid;
alter table public.shops add column if not exists group_name  text;
create index if not exists shops_group_id_idx on public.shops (group_id) where group_id is not null;

-- To group a client's branches (run once per owner), give her shops the same group_id + a label, e.g.:
--   update public.shops set group_id = gen_random_uuid(), group_name = 'Jane''s Chemists'
--     where id in ('<chemist-a-uuid>');                       -- pick/generate the group id on the FIRST shop
--   update public.shops set group_id = '<that-group-id>', group_name = 'Jane''s Chemists'
--     where id in ('<chemist-b-uuid>');                       -- then attach the sibling(s) to it

create or replace function public.owner_group_summary(p_shop_ids uuid[], p_tz text default 'Africa/Nairobi')
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_d0 timestamptz := (date_trunc('day',   (now() at time zone p_tz)) at time zone p_tz);
  v_m0 timestamptz := (date_trunc('month', (now() at time zone p_tz)) at time zone p_tz);
  v_w0 timestamptz := now() - interval '7 days';
  v_out jsonb;
begin
  with
  sale_agg as (
    select s.shop_id,
      coalesce(sum(s.total) filter (where s.ts >= v_d0),0) as t_val,
      count(*)              filter (where s.ts >= v_d0)    as t_cnt,
      coalesce(sum(s.total) filter (where s.ts >= v_w0),0) as w_val,
      count(*)              filter (where s.ts >= v_w0)    as w_cnt,
      coalesce(sum(s.total) filter (where s.ts >= v_m0),0) as m_val,
      count(*)              filter (where s.ts >= v_m0)    as m_cnt
    from public.sales s where s.shop_id = any(p_shop_ids) group by s.shop_id
  ),
  line_exp as (
    select s.shop_id, s.ts,
      (coalesce((l->>'price')::numeric,0) - coalesce((l->>'cost')::numeric,0)) * coalesce((l->>'qty')::numeric,0) as profit,
      coalesce((l->>'price')::numeric,0) * coalesce((l->>'qty')::numeric,0) as revenue,
      coalesce((l->>'qty')::numeric,0) as qty,
      coalesce(nullif(l->>'name',''), l->>'sku', '(item)') as pname
    from public.sales s
      cross join lateral jsonb_array_elements(case when jsonb_typeof(s.lines)='array' then s.lines else '[]'::jsonb end) as l
    where s.shop_id = any(p_shop_ids)
  ),
  profit_agg as (
    select shop_id,
      coalesce(sum(profit) filter (where ts >= v_d0),0) as p_today,
      coalesce(sum(profit) filter (where ts >= v_w0),0) as p_7d,
      coalesce(sum(profit) filter (where ts >= v_m0),0) as p_month
    from line_exp group by shop_id
  ),
  top_raw as (
    select shop_id, pname, sum(qty) as qty, sum(revenue) as revenue,
      row_number() over (partition by shop_id order by sum(revenue) desc, pname) as rn
    from line_exp where ts >= v_m0 group by shop_id, pname
  ),
  top_agg as (
    select shop_id, jsonb_agg(jsonb_build_object('name',pname,'qty',qty,'revenue',revenue) order by revenue desc) as top
    from top_raw where rn <= 5 group by shop_id
  ),
  staff_raw as (
    select shop_id, cashier, count(*) as sales, max(ts) as last_ts
    from public.sales where shop_id = any(p_shop_ids) and ts >= v_d0 and nullif(cashier,'') is not null
    group by shop_id, cashier
  ),
  staff_agg as (
    select shop_id, jsonb_agg(jsonb_build_object('name',cashier,'sales',sales,'last_ts',last_ts) order by last_ts desc) as staff
    from staff_raw group by shop_id
  ),
  act_raw as (
    select shop_id, actor, action, ts,
      row_number() over (partition by shop_id order by ts desc) as rn
    from public.audit_log where shop_id = any(p_shop_ids)
  ),
  act_agg as (
    select shop_id, jsonb_agg(jsonb_build_object('actor',actor,'action',action,'ts',ts) order by ts desc) as acts
    from act_raw where rn <= 8 group by shop_id
  )
  select jsonb_agg(jsonb_build_object(
    'shop_id', sh.id, 'shop_name', sh.name,
    'sales', jsonb_build_object(
       'today', jsonb_build_object('value', coalesce(sa.t_val,0), 'count', coalesce(sa.t_cnt,0)),
       'week',  jsonb_build_object('value', coalesce(sa.w_val,0), 'count', coalesce(sa.w_cnt,0)),
       'month', jsonb_build_object('value', coalesce(sa.m_val,0), 'count', coalesce(sa.m_cnt,0))
    ),
    'profit', jsonb_build_object('today', coalesce(pa.p_today,0), 'week', coalesce(pa.p_7d,0), 'month', coalesce(pa.p_month,0)),
    'top_products',    coalesce(ta.top,   '[]'::jsonb),
    'staff_today',     coalesce(st.staff, '[]'::jsonb),
    'recent_activity', coalesce(ac.acts,  '[]'::jsonb)
  ) order by sh.name)
  into v_out
  from public.shops sh
  left join sale_agg   sa on sa.shop_id = sh.id
  left join profit_agg pa on pa.shop_id = sh.id
  left join top_agg    ta on ta.shop_id = sh.id
  left join staff_agg  st on st.shop_id = sh.id
  left join act_agg    ac on ac.shop_id = sh.id
  where sh.id = any(p_shop_ids);

  return coalesce(v_out, '[]'::jsonb);
end;
$fn$;
revoke execute on function public.owner_group_summary(uuid[], text) from anon, authenticated, public;
