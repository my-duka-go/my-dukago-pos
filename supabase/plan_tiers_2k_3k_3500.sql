-- New subscription tiers the super admin can set per shop (Nov 2026).
--   xlarge    KSh 2,000 / month   up to 8 phones   "Large supermarket / hardware"
--   wholesale KSh 3,000 / month   up to 15 phones  "Wholesale / distributor"
--   chain     KSh 3,500 / month   unlimited phones "Chain / multi-branch"
--
-- The older 'xl' tier (2,500 / unlimited) is retired from the plan pickers in the app,
-- but kept priced here for backward-compatibility. Its one shop is migrated to 'wholesale'
-- (the 3,000 tier) once build 186 is live:  update public.shops set plan='wholesale' where plan='xl';
--
-- plan_yearly_price is unchanged (it derives: round(monthly * 12 * 0.90)).

create or replace function public.plan_monthly_price(p_plan text)
 returns numeric language sql immutable set search_path to 'public'
as $function$
  select (case coalesce(p_plan, 'small')
    when 'medium'    then 1000
    when 'large'     then 1500
    when 'xlarge'    then 2000
    when 'wholesale' then 3000
    when 'chain'     then 3500
    when 'xl'        then 2500
    else 500 end)::numeric
$function$;

create or replace function public.plan_device_limit(p_plan text)
 returns integer language sql immutable set search_path to 'public'
as $function$
  select case coalesce(p_plan, 'small')
    when 'medium'    then 3
    when 'large'     then 5
    when 'xlarge'    then 8
    when 'wholesale' then 15
    when 'chain'     then 100000
    when 'xl'        then 100000
    else 2 end
$function$;
