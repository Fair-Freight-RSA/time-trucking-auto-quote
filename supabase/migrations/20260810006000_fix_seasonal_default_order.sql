create or replace function public.ttaq_active_seasonal_multiplier_for_date(profile_id uuid, pricing_date date)
returns table(season_key text, multiplier numeric, rule_id uuid, display_name text)
language sql
security definer
set search_path = public
stable
as $$
  select sm.season_key, sm.multiplier, sm.id, sm.display_name
  from public.pricing_seasonal_multipliers sm
  where sm.pricing_profile_id = profile_id
    and sm.is_active
    and (sm.effective_from is null or sm.effective_from <= coalesce(pricing_date, current_date))
    and (sm.effective_to is null or sm.effective_to >= coalesce(pricing_date, current_date))
  order by
    case when sm.effective_from is not null or sm.effective_to is not null then 0 else 1 end,
    case when sm.effective_from is not null or sm.effective_to is not null then coalesce(sm.effective_from, date '1900-01-01') end desc nulls last,
    case when sm.effective_from is null and sm.effective_to is null and sm.season_key = 'normal' then 0 else 1 end,
    sm.created_at desc
  limit 1;
$$;
