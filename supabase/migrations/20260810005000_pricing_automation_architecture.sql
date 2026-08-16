create extension if not exists pgcrypto;

alter table public.diesel_price_integrations
  add column if not exists source_type text not null default 'manual_override',
  add column if not exists source_url text,
  add column if not exists freshness_days integer not null default 35,
  add column if not exists next_expected_refresh date,
  add column if not exists is_cached boolean not null default false;

alter table public.pricing_calculations
  add column if not exists pricing_source_snapshot jsonb not null default '{}'::jsonb,
  add column if not exists automation_status jsonb not null default '{}'::jsonb;

alter table public.pricing_adjustments
  add column if not exists calculated_cost_snapshot numeric(14, 2),
  add column if not exists resulting_profit numeric(14, 2),
  add column if not exists resulting_margin_percent numeric(10, 4),
  add column if not exists warning_flags jsonb not null default '[]'::jsonb;

create table if not exists public.pricing_external_providers (
  id uuid primary key default gen_random_uuid(),
  provider_key text not null unique,
  provider_name text not null,
  provider_category text not null,
  provider_status text not null default 'not_configured',
  endpoint_url text,
  refresh_cadence text,
  freshness_days integer not null default 35,
  last_success_at timestamptz,
  last_failure_at timestamptz,
  last_error text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists ttaq_pricing_external_providers_touch_updated_at on public.pricing_external_providers;
create trigger ttaq_pricing_external_providers_touch_updated_at
before update on public.pricing_external_providers
for each row execute function public.ttaq_touch_updated_at();

alter table public.pricing_external_providers enable row level security;

drop policy if exists "Internal users read pricing providers" on public.pricing_external_providers;
create policy "Internal users read pricing providers"
on public.pricing_external_providers
for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));

drop policy if exists "Owner manages pricing providers" on public.pricing_external_providers;
create policy "Owner manages pricing providers"
on public.pricing_external_providers
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

insert into public.pricing_external_providers (
  provider_key,
  provider_name,
  provider_category,
  provider_status,
  endpoint_url,
  refresh_cadence,
  freshness_days,
  notes
)
values
  (
    'za_dmre_cef_diesel',
    'South Africa DMPR/CEF diesel wholesale fuel price',
    'diesel',
    'not_configured',
    'https://www.dmpr.gov.za/Services/Petroleum-Resources/Fuel-Prices',
    'Monthly regulated wholesale diesel publication; CEF daily indicators can be monitored for early warning.',
    35,
    'Official South African diesel source identified. Live credentials/parser are not configured, so pricing remains Manual / live provider not configured.'
  ),
  (
    'google_routes',
    'Google Routes',
    'route',
    'configured_in_app_or_edge_function',
    'https://routes.googleapis.com/directions/v2:computeRoutes',
    'Per RFQ route calculation',
    7,
    'Route distance and duration are automatic when Google credentials are configured. Toll advisory is metadata only unless monetary toll values are available.'
  )
on conflict (provider_key) do update
set provider_name = excluded.provider_name,
    provider_category = excluded.provider_category,
    endpoint_url = excluded.endpoint_url,
    refresh_cadence = excluded.refresh_cadence,
    freshness_days = excluded.freshness_days,
    notes = excluded.notes;

insert into public.pricing_settings (pricing_profile_id, setting_key, setting_value, setting_unit, description)
select p.id, defaults.setting_key, defaults.setting_value, defaults.setting_unit, defaults.description
from public.pricing_profiles p
cross join (
  values
    ('minimum_selling_price', 0.0000, 'ZAR', 'Optional minimum customer selling price floor'),
    ('minimum_margin_percent', 15.0000, 'percent', 'Minimum acceptable margin warning threshold'),
    ('additional_stop_rate', 0.0000, 'ZAR/stop', 'Charge per additional stop beyond one collection and one delivery'),
    ('cross_border_surcharge', 0.0000, 'ZAR', 'Commercial surcharge when cross-border movement is detected'),
    ('diesel_max_age_days', 35.0000, 'days', 'Approved freshness period for cached diesel values'),
    ('toll_manual_review_required', 1.0000, 'boolean', 'Flag manual review when neither live toll amount nor configured toll rule is available')
) as defaults(setting_key, setting_value, setting_unit, description)
where p.is_active
on conflict (pricing_profile_id, setting_key) do nothing;

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
    case when sm.season_key = 'normal' then 1 else 0 end,
    coalesce(sm.effective_from, date '1900-01-01') desc,
    sm.created_at desc
  limit 1;
$$;

create or replace function public.ttaq_current_diesel_input(profile_id uuid)
returns table(
  price_per_litre numeric,
  source_label text,
  provider_name text,
  provider_status text,
  effective_from date,
  retrieved_at timestamptz,
  previous_price_per_litre numeric,
  manual_override boolean,
  is_cached boolean,
  requires_review boolean,
  source_payload jsonb
)
language sql
security definer
set search_path = public
stable
as $$
  with settings as (
    select greatest(public.ttaq_pricing_setting(profile_id, 'diesel_max_age_days'), 1) as max_age_days
  ),
  live_value as (
    select
      coalesce(d.provider_price_per_litre, d.admin_override_price_per_litre) as price_per_litre,
      case
        when d.provider_price_per_litre is not null and d.provider_status in ('success', 'verified', 'live') then 'Live provider'
        when d.provider_price_per_litre is not null then 'Cached provider'
        when d.admin_override_price_per_litre is not null then 'Manual override'
        else 'Manual / live provider not configured'
      end as source_label,
      d.provider_name,
      d.provider_status,
      d.effective_from,
      coalesce(d.refreshed_at, d.created_at) as retrieved_at,
      d.previous_price_per_litre,
      coalesce(d.manual_override_enabled, false) and d.admin_override_price_per_litre is not null as manual_override,
      coalesce(d.is_cached, false)
        or (d.provider_price_per_litre is not null and coalesce(d.refreshed_at, d.created_at) < now() - ((select max_age_days from settings)::text || ' days')::interval) as is_cached,
      d.provider_response
    from public.diesel_price_integrations d
    where d.pricing_profile_id = profile_id
      and d.effective_from <= current_date
    order by
      case when d.provider_price_per_litre is not null and d.provider_status in ('success', 'verified', 'live') then 0 else 1 end,
      d.effective_from desc,
      d.created_at desc
    limit 1
  ),
  history_value as (
    select f.fuel_price_per_litre, f.effective_from, f.created_at
    from public.fuel_price_history f
    where f.pricing_profile_id = profile_id
    order by f.effective_from desc, f.created_at desc
    limit 1
  )
  select
    coalesce(live_value.price_per_litre, history_value.fuel_price_per_litre, 0),
    coalesce(live_value.source_label, case when history_value.fuel_price_per_litre is not null then 'Configured fallback' else 'Manual / live provider not configured' end),
    coalesce(live_value.provider_name, 'manual_admin_override'),
    coalesce(live_value.provider_status, 'not_configured'),
    coalesce(live_value.effective_from, history_value.effective_from),
    coalesce(live_value.retrieved_at, history_value.created_at),
    live_value.previous_price_per_litre,
    coalesce(live_value.manual_override, false),
    coalesce(live_value.is_cached, false),
    coalesce(live_value.price_per_litre, history_value.fuel_price_per_litre, 0) <= 0,
    jsonb_build_object(
      'source_label', coalesce(live_value.source_label, case when history_value.fuel_price_per_litre is not null then 'Configured fallback' else 'Manual / live provider not configured' end),
      'provider_name', coalesce(live_value.provider_name, 'manual_admin_override'),
      'provider_status', coalesce(live_value.provider_status, 'not_configured'),
      'effective_from', coalesce(live_value.effective_from, history_value.effective_from),
      'retrieved_at', coalesce(live_value.retrieved_at, history_value.created_at),
      'previous_price_per_litre', live_value.previous_price_per_litre,
      'manual_override', coalesce(live_value.manual_override, false),
      'is_cached', coalesce(live_value.is_cached, false),
      'provider_response', coalesce(live_value.provider_response, '{}'::jsonb)
    )
  from settings
  left join live_value on true
  left join history_value on true;
$$;

create or replace function public.ttaq_record_diesel_provider_result(
  provider_key_value text,
  provider_status_value text,
  provider_price_per_litre_value numeric default null,
  effective_from_value date default current_date,
  provider_response_value jsonb default '{}'::jsonb,
  error_message_value text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_id uuid;
  provider_record public.pricing_external_providers%rowtype;
  previous_price numeric;
  result_id uuid;
begin
  select *
    into provider_record
  from public.pricing_external_providers
  where provider_key = provider_key_value;

  if provider_record.id is null then
    raise exception 'Pricing provider is not configured: %', provider_key_value;
  end if;

  profile_id := public.ttaq_active_pricing_profile();
  if profile_id is null then
    raise exception 'No active pricing profile configured';
  end if;

  select coalesce(provider_price_per_litre, admin_override_price_per_litre)
    into previous_price
  from public.diesel_price_integrations
  where pricing_profile_id = profile_id
  order by effective_from desc, created_at desc
  limit 1;

  if provider_status_value in ('success', 'verified', 'live') and coalesce(provider_price_per_litre_value, 0) <= 0 then
    raise exception 'Successful diesel provider result requires a positive price';
  end if;

  insert into public.diesel_price_integrations (
    pricing_profile_id,
    provider_name,
    provider_status,
    provider_id,
    provider_price_per_litre,
    admin_override_price_per_litre,
    previous_price_per_litre,
    effective_from,
    refreshed_at,
    manual_override_enabled,
    source_type,
    source_url,
    freshness_days,
    next_expected_refresh,
    is_cached,
    error_message,
    provider_response
  )
  values (
    profile_id,
    provider_key_value,
    provider_status_value,
    provider_key_value,
    case when provider_status_value in ('success', 'verified', 'live') then provider_price_per_litre_value else null end,
    null,
    previous_price,
    coalesce(effective_from_value, current_date),
    now(),
    false,
    'live_provider',
    provider_record.endpoint_url,
    provider_record.freshness_days,
    coalesce(effective_from_value, current_date) + provider_record.freshness_days,
    provider_status_value not in ('success', 'verified', 'live'),
    nullif(error_message_value, ''),
    coalesce(provider_response_value, '{}'::jsonb) || jsonb_build_object(
      'provider_key', provider_key_value,
      'display_source', case when provider_status_value in ('success', 'verified', 'live') then provider_record.provider_name else 'Provider failed; cached/manual hierarchy applies' end
    )
  )
  returning id into result_id;

  update public.pricing_external_providers
     set provider_status = case when provider_status_value in ('success', 'verified', 'live') then 'configured' else 'failed' end,
         last_success_at = case when provider_status_value in ('success', 'verified', 'live') then now() else last_success_at end,
         last_failure_at = case when provider_status_value in ('success', 'verified', 'live') then last_failure_at else now() end,
         last_error = nullif(error_message_value, '')
   where id = provider_record.id;

  return result_id;
end;
$$;

revoke all on function public.ttaq_record_diesel_provider_result(text, text, numeric, date, jsonb, text) from public;
revoke all on function public.ttaq_record_diesel_provider_result(text, text, numeric, date, jsonb, text) from anon;
revoke all on function public.ttaq_record_diesel_provider_result(text, text, numeric, date, jsonb, text) from authenticated;
grant execute on function public.ttaq_record_diesel_provider_result(text, text, numeric, date, jsonb, text) to service_role;

create or replace function public.ttaq_generate_price(
  target_quote_request_id uuid,
  estimated_distance_km numeric default 0,
  estimated_duration_hours numeric default 0
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_id uuid;
  request_record public.quote_requests%rowtype;
  recommendation public.vehicle_recommendations%rowtype;
  route_record public.route_estimates%rowtype;
  selected_equipment public.standard_equipment_profiles%rowtype;
  vehicle_cost public.vehicle_operating_costs%rowtype;
  driver_cost public.driver_costs%rowtype;
  overhead public.company_overheads%rowtype;
  margin_profile public.company_margin_profiles%rowtype;
  diesel_record record;
  season_record record;
  fuel_price numeric := 0;
  diesel_base_price numeric := 0;
  fuel_surcharge_enabled boolean := true;
  fuel_surcharge_percent numeric := 0;
  seasonal_key text := 'normal';
  seasonal_multiplier_value numeric := 1;
  total_weight numeric := 0;
  total_volume numeric := 0;
  total_value numeric := 0;
  unit_count numeric := 1;
  overnight_count numeric := 0;
  additional_stop_count integer := 0;
  additional_stop_amount numeric := 0;
  cross_border_detected boolean := false;
  cross_border_amount numeric := 0;
  fuel_amount numeric := 0;
  fuel_surcharge_amount numeric := 0;
  tyres_amount numeric := 0;
  maintenance_amount numeric := 0;
  insurance_amount numeric := 0;
  depreciation_amount numeric := 0;
  driver_amount numeric := 0;
  overnight_amount numeric := 0;
  vehicle_overhead_amount numeric := 0;
  company_overhead_amount numeric := 0;
  escort_amount numeric := 0;
  permit_amount numeric := 0;
  hazmat_amount numeric := 0;
  refrigeration_amount numeric := 0;
  crane_amount numeric := 0;
  forklift_amount numeric := 0;
  high_value_amount numeric := 0;
  toll_amount numeric := 0;
  toll_rule_count integer := 0;
  toll_source text := 'manual_review_required';
  route_risk_amount numeric := 0;
  seasonal_amount numeric := 0;
  base_cost_value numeric := 0;
  subtotal_value numeric := 0;
  profit_value numeric := 0;
  vat_value numeric := 0;
  grand_total_value numeric := 0;
  minimum_selling_price numeric := 0;
  minimum_margin_percent numeric := 0;
  calculation_id uuid;
  currency_value text := 'ZAR';
  rule_version_value text := 'pricing-v3-automation';
  route_text text := '';
  route_review_required boolean := false;
  source_snapshot jsonb := '{}'::jsonb;
  automation_status_value jsonb := '{}'::jsonb;
begin
  profile_id := public.ttaq_active_pricing_profile();
  if profile_id is null then
    raise exception 'No active pricing profile configured';
  end if;

  select * into request_record
  from public.quote_requests
  where id = target_quote_request_id;

  select * into recommendation
  from public.vehicle_recommendations
  where quote_request_id = target_quote_request_id
  order by created_at desc
  limit 1;

  if recommendation.id is null then
    perform public.ttaq_generate_vehicle_recommendation(target_quote_request_id);
    select * into recommendation
    from public.vehicle_recommendations
    where quote_request_id = target_quote_request_id
    order by created_at desc
    limit 1;
  end if;

  select * into selected_equipment
  from public.standard_equipment_profiles
  where id = recommendation.final_equipment_profile_id;

  select * into route_record
  from public.route_estimates
  where quote_request_id = target_quote_request_id
  order by created_at desc
  limit 1;

  if route_record.id is not null then
    estimated_distance_km := coalesce(nullif(estimated_distance_km, 0), route_record.total_distance_km, route_record.manual_distance_km, 0);
    estimated_duration_hours := coalesce(nullif(estimated_duration_hours, 0), route_record.total_duration_hours, route_record.manual_duration_hours, 0);
    route_text := lower(concat_ws(' ', route_record.origin_address, route_record.destination_address, route_record.route_notes));
  end if;

  select coalesce(sum(coalesce(
           nullif(substring(coalesce(notes, '') from 'Total shipment weight:\s*([0-9]+(?:\.[0-9]+)?)\s*kg'), '')::numeric,
           coalesce(quantity, 1) * coalesce(weight_kg, 0)
         )), 0),
         coalesce(sum(coalesce(quantity, 1) * coalesce(length_m, 0) * coalesce(width_m, 0) * coalesce(height_m, 0)), 0),
         coalesce(sum(coalesce(cargo_value, 0)), 0)
    into total_weight, total_volume, total_value
  from public.quote_items
  where quote_request_id = target_quote_request_id;

  select greatest(count(*) - 2, 0)::integer,
         coalesce(bool_or(stop_type = 'border'), false)
    into additional_stop_count, cross_border_detected
  from public.quote_stops
  where quote_request_id = target_quote_request_id;

  cross_border_detected := coalesce(cross_border_detected, false)
    or lower(concat_ws(' ', request_record.collection_address, request_record.delivery_address, route_text)) ~
       '(botswana|namibia|zimbabwe|mozambique|lesotho|eswatini|swaziland|zambia|malawi|border)';

  select * into vehicle_cost
  from public.vehicle_operating_costs
  where pricing_profile_id = profile_id
    and (
      vehicle_type = coalesce(selected_equipment.display_name, recommendation.override_vehicle_type, recommendation.recommended_vehicle_type)
      or vehicle_type = coalesce(recommendation.override_vehicle_type, recommendation.recommended_vehicle_type)
      or vehicle_type = 'default'
    )
  order by case
    when vehicle_type = coalesce(selected_equipment.display_name, '') then 0
    when vehicle_type = coalesce(recommendation.override_vehicle_type, recommendation.recommended_vehicle_type) then 1
    else 2
  end
  limit 1;

  select * into driver_cost
  from public.driver_costs
  where pricing_profile_id = profile_id
  order by created_at desc
  limit 1;

  select * into overhead
  from public.company_overheads
  where pricing_profile_id = profile_id
  order by created_at desc
  limit 1;

  select * into margin_profile
  from public.company_margin_profiles
  where pricing_profile_id = profile_id
    and is_active
  order by is_default desc, created_at desc
  limit 1;

  select * into season_record
  from public.ttaq_active_seasonal_multiplier_for_date(profile_id, coalesce(request_record.collection_date, current_date));

  seasonal_key := coalesce(season_record.season_key, 'normal');
  seasonal_multiplier_value := coalesce(season_record.multiplier, public.ttaq_pricing_setting(profile_id, 'seasonal_normal_multiplier'), 1);

  select * into diesel_record
  from public.ttaq_current_diesel_input(profile_id);

  fuel_price := coalesce(diesel_record.price_per_litre, 0);
  diesel_base_price := nullif(public.ttaq_pricing_setting(profile_id, 'diesel_base_price_per_litre'), 0);
  fuel_surcharge_enabled := public.ttaq_pricing_setting(profile_id, 'fuel_surcharge_enabled') <> 0;
  unit_count := greatest(1, coalesce(recommendation.number_of_trucks, 1));
  overnight_count := floor(coalesce(estimated_duration_hours, 0) / 24);

  fuel_amount := round(coalesce(estimated_distance_km, 0) * unit_count * (coalesce(selected_equipment.fuel_consumption_l_per_100km, vehicle_cost.fuel_consumption_l_per_100km, 0) / 100) * fuel_price, 2);
  fuel_surcharge_percent := case
    when fuel_surcharge_enabled and diesel_base_price is not null and fuel_price > diesel_base_price
      then round(((fuel_price - diesel_base_price) / diesel_base_price) * 100, 4)
    else 0
  end;
  fuel_surcharge_amount := round(fuel_amount * (fuel_surcharge_percent / 100), 2);
  tyres_amount := round(coalesce(estimated_distance_km, 0) * unit_count * coalesce(selected_equipment.average_tyre_cost_per_km, vehicle_cost.average_tyre_cost_per_km, 0), 2);
  maintenance_amount := round(coalesce(estimated_distance_km, 0) * unit_count * coalesce(selected_equipment.maintenance_cost_per_km, vehicle_cost.maintenance_cost_per_km, 0), 2);
  insurance_amount := round(coalesce(estimated_distance_km, 0) * unit_count * coalesce(selected_equipment.insurance_cost_per_km, vehicle_cost.insurance_cost_per_km, 0), 2);
  depreciation_amount := round(coalesce(estimated_distance_km, 0) * unit_count * coalesce(selected_equipment.depreciation_cost_per_km, vehicle_cost.depreciation_cost_per_km, 0), 2);
  driver_amount := round(coalesce(estimated_duration_hours, 0) * unit_count * coalesce(driver_cost.driver_hourly_wage, 0), 2);
  overnight_amount := round(overnight_count * unit_count * coalesce(driver_cost.driver_overnight_allowance, 0), 2);
  vehicle_overhead_amount := round(coalesce(estimated_distance_km, 0) * unit_count * coalesce(selected_equipment.vehicle_overhead_per_km, vehicle_cost.vehicle_overhead_per_km, 0), 2);

  escort_amount := case when coalesce(recommendation.escort_recommended, false) then public.ttaq_pricing_setting(profile_id, 'escort_surcharge') else 0 end;
  permit_amount := case when coalesce(recommendation.permit_required, false) then public.ttaq_pricing_setting(profile_id, 'permit_surcharge') else 0 end;
  hazmat_amount := case when coalesce(recommendation.hazmat_required, false) then public.ttaq_pricing_setting(profile_id, 'hazmat_surcharge') else 0 end;
  refrigeration_amount := case when coalesce(recommendation.refrigeration_required, false) then public.ttaq_pricing_setting(profile_id, 'refrigeration_surcharge') else 0 end;
  crane_amount := case when coalesce(recommendation.crane_required, false) then public.ttaq_pricing_setting(profile_id, 'crane_surcharge') else 0 end;
  forklift_amount := case when coalesce(recommendation.forklift_required, false) then public.ttaq_pricing_setting(profile_id, 'forklift_surcharge') else 0 end;
  high_value_amount := case when total_value >= public.ttaq_pricing_setting(profile_id, 'high_value_threshold') and public.ttaq_pricing_setting(profile_id, 'high_value_threshold') > 0 then public.ttaq_pricing_setting(profile_id, 'high_value_surcharge') else 0 end;
  additional_stop_amount := additional_stop_count * public.ttaq_pricing_setting(profile_id, 'additional_stop_rate');
  cross_border_amount := case when cross_border_detected then public.ttaq_pricing_setting(profile_id, 'cross_border_surcharge') else 0 end;

  select count(*),
         coalesce(sum(fixed_amount + (amount_per_km * coalesce(estimated_distance_km, 0))), 0)
    into toll_rule_count, toll_amount
  from public.toll_cost_rules
  where pricing_profile_id = profile_id
    and is_active
    and (route_keyword is null or route_text like '%' || lower(route_keyword) || '%')
    and (origin_keyword is null or lower(coalesce(route_record.origin_address, request_record.collection_address, '')) like '%' || lower(origin_keyword) || '%')
    and (destination_keyword is null or lower(coalesce(route_record.destination_address, request_record.delivery_address, '')) like '%' || lower(destination_keyword) || '%');

  if coalesce(toll_rule_count, 0) > 0 then
    toll_source := 'configured_rule';
  elsif public.ttaq_pricing_setting(profile_id, 'default_toll_cost') > 0 then
    toll_amount := public.ttaq_pricing_setting(profile_id, 'default_toll_cost');
    toll_source := 'configured_fallback';
  else
    toll_amount := 0;
    toll_source := case when route_record.provider_response ? 'toll_info' then 'live_metadata_no_amount' else 'manual_review_required' end;
    route_review_required := route_review_required or (public.ttaq_pricing_setting(profile_id, 'toll_manual_review_required') <> 0);
  end if;

  base_cost_value := fuel_amount + fuel_surcharge_amount + tyres_amount + maintenance_amount + insurance_amount + depreciation_amount + driver_amount + overnight_amount + vehicle_overhead_amount + escort_amount + permit_amount + hazmat_amount + refrigeration_amount + crane_amount + forklift_amount + high_value_amount + additional_stop_amount + cross_border_amount + toll_amount;

  select coalesce(sum(fixed_surcharge + (base_cost_value * (surcharge_percent / 100))), public.ttaq_pricing_setting(profile_id, 'default_route_risk_surcharge'), 0),
         bool_or(manager_review_required)
    into route_risk_amount, route_review_required
  from public.route_risk_pricing_rules
  where pricing_profile_id = profile_id
    and is_active
    and (min_distance_km is null or coalesce(estimated_distance_km, 0) >= min_distance_km)
    and (route_keyword is null or route_text like '%' || lower(route_keyword) || '%')
    and (origin_keyword is null or lower(coalesce(route_record.origin_address, request_record.collection_address, '')) like '%' || lower(origin_keyword) || '%')
    and (destination_keyword is null or lower(coalesce(route_record.destination_address, request_record.delivery_address, '')) like '%' || lower(destination_keyword) || '%');

  base_cost_value := base_cost_value + coalesce(route_risk_amount, 0);
  seasonal_amount := round(base_cost_value * (seasonal_multiplier_value - 1), 2);
  subtotal_value := base_cost_value + seasonal_amount;
  company_overhead_amount := round(subtotal_value * (coalesce(overhead.admin_overhead_percent, 0) / 100), 2);
  subtotal_value := subtotal_value + company_overhead_amount;
  profit_value := greatest(
    round(subtotal_value * (coalesce(margin_profile.margin_percent, overhead.profit_margin_percent, 0) / 100), 2),
    coalesce(margin_profile.minimum_profit, overhead.minimum_profit, 0)
  );
  vat_value := round((subtotal_value + profit_value) * (coalesce(overhead.vat_percent, 0) / 100), 2);
  grand_total_value := subtotal_value + profit_value + vat_value;
  minimum_selling_price := public.ttaq_pricing_setting(profile_id, 'minimum_selling_price');
  minimum_margin_percent := public.ttaq_pricing_setting(profile_id, 'minimum_margin_percent');

  if minimum_selling_price > 0 and grand_total_value < minimum_selling_price then
    grand_total_value := minimum_selling_price;
    route_review_required := true;
  end if;

  select currency, rule_version into currency_value, rule_version_value
  from public.pricing_profiles
  where id = profile_id;

  source_snapshot := jsonb_build_object(
    'diesel', diesel_record.source_payload,
    'route', jsonb_build_object(
      'distance_km', estimated_distance_km,
      'duration_hours', estimated_duration_hours,
      'source', coalesce(route_record.provider_name, 'manual_or_unavailable'),
      'provider_status', route_record.provider_status,
      'calculated_at', route_record.estimated_at
    ),
    'tolls', jsonb_build_object(
      'amount', toll_amount,
      'source', toll_source,
      'matched_rule_count', coalesce(toll_rule_count, 0),
      'provider_toll_status', coalesce(route_record.toll_status, route_record.provider_response->>'toll_status')
    ),
    'season', jsonb_build_object(
      'season_key', seasonal_key,
      'display_name', season_record.display_name,
      'multiplier', seasonal_multiplier_value,
      'rule_id', season_record.rule_id,
      'pricing_date', coalesce(request_record.collection_date, current_date)
    ),
    'equipment', jsonb_build_object(
      'selected_equipment_profile_id', selected_equipment.id,
      'selected_equipment', coalesce(selected_equipment.display_name, recommendation.override_vehicle_type, recommendation.recommended_vehicle_type),
      'unit_count', unit_count,
      'equipment_source', recommendation.equipment_source
    )
  );

  automation_status_value := jsonb_build_object(
    'diesel_requires_review', coalesce(diesel_record.requires_review, true),
    'route_requires_review', coalesce(estimated_distance_km, 0) <= 0,
    'toll_requires_review', toll_source in ('manual_review_required', 'live_metadata_no_amount'),
    'cross_border_detected', cross_border_detected,
    'additional_stop_count', additional_stop_count,
    'minimum_selling_price_applied', minimum_selling_price > 0 and grand_total_value = minimum_selling_price,
    'minimum_margin_percent', minimum_margin_percent
  );

  insert into public.pricing_calculations (
    quote_request_id, vehicle_recommendation_id, pricing_profile_id, rule_version,
    estimated_distance_km, estimated_duration_hours, total_weight_kg, total_volume_m3,
    subtotal, profit_amount, vat_amount, grand_total, recommended_selling_price,
    currency, calculation_notes, fuel_price_per_litre, fuel_surcharge_amount,
    seasonal_multiplier, seasonal_amount, toll_amount, route_risk_amount,
    margin_profile_key, margin_percent, dynamic_inputs, dynamic_outputs, manager_review_required,
    pricing_source_snapshot, automation_status
  )
  values (
    target_quote_request_id, recommendation.id, profile_id, coalesce(rule_version_value, 'pricing-v3-automation'),
    coalesce(estimated_distance_km, 0), coalesce(estimated_duration_hours, 0), total_weight, total_volume,
    subtotal_value, profit_value, vat_value, grand_total_value, grand_total_value,
    coalesce(currency_value, 'ZAR'),
    'Automated pricing generated from route, diesel source hierarchy, selected equipment economics, stops, border detection, seasonal/risk/toll rules, margin, minimum-profit, and VAT.',
    fuel_price, fuel_surcharge_amount, seasonal_multiplier_value, seasonal_amount, toll_amount, route_risk_amount,
    margin_profile.margin_key, coalesce(margin_profile.margin_percent, overhead.profit_margin_percent, 0),
    source_snapshot,
    jsonb_build_object(
      'vehicle_dependent_costs_multiplier', unit_count,
      'calculated_cost_before_profit_vat', subtotal_value,
      'fuel_amount', fuel_amount,
      'fuel_surcharge_percent', fuel_surcharge_percent,
      'fuel_surcharge_amount', fuel_surcharge_amount,
      'tyres_amount', tyres_amount,
      'maintenance_amount', maintenance_amount,
      'vehicle_insurance_amount', insurance_amount,
      'depreciation_amount', depreciation_amount,
      'driver_amount', driver_amount + overnight_amount,
      'vehicle_overhead_amount', vehicle_overhead_amount,
      'additional_stop_amount', additional_stop_amount,
      'cross_border_amount', cross_border_amount,
      'shipment_level_surcharges', escort_amount + permit_amount + hazmat_amount + refrigeration_amount + crane_amount + forklift_amount + high_value_amount + additional_stop_amount + cross_border_amount,
      'base_cost_before_seasonal', base_cost_value,
      'toll_amount', toll_amount,
      'route_risk_amount', route_risk_amount,
      'seasonal_amount', seasonal_amount,
      'company_overhead_amount', company_overhead_amount,
      'profit_amount', profit_value,
      'expected_margin_percent', round((profit_value / nullif(subtotal_value, 0)) * 100, 4),
      'vat_amount', vat_value,
      'grand_total', grand_total_value
    ),
    coalesce(route_review_required, false)
      or coalesce(recommendation.manager_review_required, false)
      or coalesce(diesel_record.requires_review, true)
      or coalesce(estimated_distance_km, 0) <= 0,
    source_snapshot,
    automation_status_value
  )
  returning id into calculation_id;

  insert into public.pricing_breakdowns (pricing_calculation_id, quote_request_id, line_key, line_label, quantity, unit_rate, amount, explanation)
  values
    (calculation_id, target_quote_request_id, 'fuel', 'Fuel', coalesce(estimated_distance_km, 0) * unit_count, fuel_price, fuel_amount, 'Distance x selected equipment fuel consumption x current diesel price x unit count'),
    (calculation_id, target_quote_request_id, 'fuel_surcharge', 'Fuel surcharge', fuel_amount, fuel_surcharge_percent, fuel_surcharge_amount, 'Automatic surcharge when current diesel is above configured baseline'),
    (calculation_id, target_quote_request_id, 'driver', 'Driver', coalesce(estimated_duration_hours, 0) * unit_count, coalesce(driver_cost.driver_hourly_wage, 0), driver_amount + overnight_amount, 'Driver wages plus overnight allowance per vehicle unit'),
    (calculation_id, target_quote_request_id, 'maintenance', 'Maintenance', coalesce(estimated_distance_km, 0) * unit_count, coalesce(selected_equipment.maintenance_cost_per_km, vehicle_cost.maintenance_cost_per_km, 0), maintenance_amount, 'Distance x selected equipment maintenance cost/km x unit count'),
    (calculation_id, target_quote_request_id, 'tyres', 'Tyres', coalesce(estimated_distance_km, 0) * unit_count, coalesce(selected_equipment.average_tyre_cost_per_km, vehicle_cost.average_tyre_cost_per_km, 0), tyres_amount, 'Distance x selected equipment tyre cost/km x unit count'),
    (calculation_id, target_quote_request_id, 'insurance', 'Insurance', coalesce(estimated_distance_km, 0) * unit_count, coalesce(selected_equipment.insurance_cost_per_km, vehicle_cost.insurance_cost_per_km, 0), insurance_amount, 'Distance x selected equipment insurance cost/km x unit count'),
    (calculation_id, target_quote_request_id, 'depreciation', 'Depreciation', coalesce(estimated_distance_km, 0) * unit_count, coalesce(selected_equipment.depreciation_cost_per_km, vehicle_cost.depreciation_cost_per_km, 0), depreciation_amount, 'Distance x selected equipment depreciation cost/km x unit count'),
    (calculation_id, target_quote_request_id, 'additional_stops', 'Additional stops', additional_stop_count, public.ttaq_pricing_setting(profile_id, 'additional_stop_rate'), additional_stop_amount, 'Automatically counted from RFQ stops beyond one collection and one delivery'),
    (calculation_id, target_quote_request_id, 'cross_border', 'Cross-border', case when cross_border_detected then 1 else 0 end, public.ttaq_pricing_setting(profile_id, 'cross_border_surcharge'), cross_border_amount, 'Automatically detected from border stop or cross-border route/address text'),
    (calculation_id, target_quote_request_id, 'tolls', 'Tolls', coalesce(estimated_distance_km, 0), toll_amount, toll_amount, 'Live toll amount if configured, otherwise matching Time Trucking toll rule or manual review'),
    (calculation_id, target_quote_request_id, 'route_risk', 'Route risk', base_cost_value, 0, route_risk_amount, 'Configurable route risk rules matched against distance and route text'),
    (calculation_id, target_quote_request_id, 'seasonal_multiplier', 'Seasonal multiplier', base_cost_value, seasonal_multiplier_value, seasonal_amount, 'Seasonal multiplier selected automatically from collection date'),
    (calculation_id, target_quote_request_id, 'overhead', 'Overhead', subtotal_value, coalesce(overhead.admin_overhead_percent, 0), company_overhead_amount + vehicle_overhead_amount, 'Vehicle overhead is per unit; company admin overhead is percentage-based'),
    (calculation_id, target_quote_request_id, 'escort', 'Escort', 1, escort_amount, escort_amount, 'Shipment-level escort surcharge when recommended'),
    (calculation_id, target_quote_request_id, 'permit', 'Permit', 1, permit_amount, permit_amount, 'Shipment-level permit surcharge when required'),
    (calculation_id, target_quote_request_id, 'hazmat', 'Hazmat', 1, hazmat_amount, hazmat_amount, 'Shipment-level dangerous goods surcharge'),
    (calculation_id, target_quote_request_id, 'refrigeration', 'Refrigeration', 1, refrigeration_amount, refrigeration_amount, 'Shipment-level refrigeration surcharge'),
    (calculation_id, target_quote_request_id, 'crane', 'Crane', 1, crane_amount, crane_amount, 'Shipment-level crane surcharge'),
    (calculation_id, target_quote_request_id, 'forklift', 'Forklift', 1, forklift_amount, forklift_amount, 'Shipment-level forklift surcharge'),
    (calculation_id, target_quote_request_id, 'high_value', 'High-value cargo', 1, high_value_amount, high_value_amount, 'Shipment-level surcharge when cargo value exceeds threshold'),
    (calculation_id, target_quote_request_id, 'profit', 'Margin / profit', subtotal_value, coalesce(margin_profile.margin_percent, overhead.profit_margin_percent, 0), profit_value, 'Company margin profile with minimum profit applied'),
    (calculation_id, target_quote_request_id, 'vat', 'VAT', subtotal_value + profit_value, coalesce(overhead.vat_percent, 0), vat_value, 'VAT applied after profit');

  insert into public.pricing_calculation_audit_events (quote_request_id, pricing_calculation_id, event_type, event_payload, created_by)
  values (
    target_quote_request_id,
    calculation_id,
    'automated_price_generated',
    jsonb_build_object(
      'rule_version', coalesce(rule_version_value, 'pricing-v3-automation'),
      'recommended_selling_price', grand_total_value,
      'source_snapshot', source_snapshot,
      'automation_status', automation_status_value,
      'manager_review_required', coalesce(route_review_required, false) or coalesce(recommendation.manager_review_required, false)
    ),
    auth.uid()
  );

  update public.quote_requests
     set adjusted_price = grand_total_value
   where id = target_quote_request_id;

  return calculation_id;
end;
$$;

create or replace function public.ttaq_record_pricing_adjustment(
  target_quote_request_id uuid,
  target_pricing_calculation_id uuid,
  adjusted_selling_price_value numeric,
  adjustment_reason_value text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  calculation public.pricing_calculations%rowtype;
  profile_id uuid;
  previous_price numeric;
  calculated_cost numeric;
  resulting_profit_value numeric;
  resulting_margin_value numeric;
  target_margin numeric;
  minimum_margin numeric;
  minimum_profit numeric;
  warnings jsonb := '[]'::jsonb;
  adjustment_id uuid;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Not allowed to adjust pricing';
  end if;

  if nullif(adjustment_reason_value, '') is null then
    raise exception 'Override reason is required';
  end if;

  select * into calculation
  from public.pricing_calculations
  where id = target_pricing_calculation_id;

  if calculation.id is null then
    raise exception 'Pricing calculation not found';
  end if;

  profile_id := calculation.pricing_profile_id;
  previous_price := calculation.recommended_selling_price;
  calculated_cost := coalesce((calculation.dynamic_outputs->>'calculated_cost_before_profit_vat')::numeric, calculation.subtotal - calculation.profit_amount, calculation.subtotal, 0);
  resulting_profit_value := coalesce(adjusted_selling_price_value, 0) - coalesce(calculated_cost, 0) - coalesce(calculation.vat_amount, 0);
  resulting_margin_value := round((resulting_profit_value / nullif(adjusted_selling_price_value - coalesce(calculation.vat_amount, 0), 0)) * 100, 4);
  target_margin := coalesce(calculation.margin_percent, 0);
  minimum_margin := public.ttaq_pricing_setting(profile_id, 'minimum_margin_percent');

  select coalesce(cmp.minimum_profit, co.minimum_profit, 0)
    into minimum_profit
  from public.pricing_profiles pp
  left join public.company_margin_profiles cmp on cmp.pricing_profile_id = pp.id and cmp.is_default and cmp.is_active
  left join public.company_overheads co on co.pricing_profile_id = pp.id
  where pp.id = profile_id
  order by co.created_at desc
  limit 1;

  if resulting_profit_value < 0 then
    warnings := warnings || jsonb_build_array('selling_price_below_calculated_cost');
  end if;
  if resulting_margin_value < target_margin then
    warnings := warnings || jsonb_build_array('margin_below_target');
  end if;
  if resulting_margin_value < minimum_margin then
    warnings := warnings || jsonb_build_array('margin_below_configured_minimum');
  end if;
  if resulting_profit_value < minimum_profit then
    warnings := warnings || jsonb_build_array('profit_below_configured_minimum');
  end if;

  insert into public.pricing_adjustments (
    quote_request_id,
    pricing_calculation_id,
    adjusted_selling_price,
    previous_selling_price,
    adjustment_reason,
    adjusted_by,
    calculated_cost_snapshot,
    resulting_profit,
    resulting_margin_percent,
    warning_flags
  )
  values (
    target_quote_request_id,
    target_pricing_calculation_id,
    adjusted_selling_price_value,
    previous_price,
    adjustment_reason_value,
    auth.uid(),
    calculated_cost,
    resulting_profit_value,
    resulting_margin_value,
    warnings
  )
  returning id into adjustment_id;

  insert into public.pricing_calculation_audit_events (quote_request_id, pricing_calculation_id, event_type, event_payload, created_by)
  values (
    target_quote_request_id,
    target_pricing_calculation_id,
    'manager_price_override_recorded',
    jsonb_build_object(
      'previous_selling_price', previous_price,
      'adjusted_selling_price', adjusted_selling_price_value,
      'calculated_cost', calculated_cost,
      'resulting_profit', resulting_profit_value,
      'resulting_margin_percent', resulting_margin_value,
      'warning_flags', warnings,
      'reason', adjustment_reason_value
    ),
    auth.uid()
  );

  update public.quote_requests
     set adjusted_price = adjusted_selling_price_value
   where id = target_quote_request_id;

  return adjustment_id;
end;
$$;

create or replace function public.ttaq_save_diesel_integration_settings(
  settings_payload jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_id uuid;
  current_price numeric;
  baseline_price numeric;
  previous_price numeric;
  surcharge_percent numeric;
  manual_enabled boolean;
  freshness_days_value integer;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules') then
    raise exception 'Only approved Time Trucking pricing users can update diesel settings.';
  end if;

  select id
    into profile_id
  from public.pricing_profiles
  where is_active = true
  order by created_at desc
  limit 1;

  if profile_id is null then
    raise exception 'No active pricing profile exists.';
  end if;

  current_price := coalesce(
    nullif(settings_payload->>'diesel_admin_override_price_per_litre', '')::numeric,
    nullif(settings_payload->>'fuel_price_per_litre', '')::numeric,
    0
  );
  baseline_price := nullif(settings_payload->>'diesel_base_price_per_litre', '')::numeric;
  previous_price := nullif(settings_payload->>'diesel_previous_price_per_litre', '')::numeric;
  manual_enabled := coalesce(settings_payload->>'diesel_manual_override_enabled', 'true') in ('true', '1', 'on', 'yes');
  freshness_days_value := greatest(coalesce(nullif(settings_payload->>'diesel_max_age_days', '')::integer, public.ttaq_pricing_setting(profile_id, 'diesel_max_age_days')::integer, 35), 1);
  surcharge_percent := case
    when baseline_price is not null and baseline_price > 0 and current_price > baseline_price
      then round(((current_price - baseline_price) / baseline_price) * 100, 4)
    else 0
  end;

  insert into public.diesel_price_integrations (
    pricing_profile_id,
    provider_name,
    provider_status,
    provider_id,
    provider_price_per_litre,
    admin_override_price_per_litre,
    previous_price_per_litre,
    surcharge_percent_snapshot,
    effective_from,
    refreshed_at,
    manual_override_enabled,
    source_type,
    source_url,
    freshness_days,
    next_expected_refresh,
    is_cached,
    provider_response
  )
  values (
    profile_id,
    'manual_admin_override',
    'manual_fallback',
    nullif(settings_payload->>'diesel_provider_id', ''),
    null,
    current_price,
    previous_price,
    surcharge_percent,
    coalesce(nullif(settings_payload->>'diesel_effective_from', '')::date, current_date),
    coalesce(nullif(settings_payload->>'diesel_refreshed_at', '')::timestamptz, now()),
    manual_enabled,
    'manual_override',
    'https://www.dmpr.gov.za/Services/Petroleum-Resources/Fuel-Prices',
    freshness_days_value,
    coalesce(nullif(settings_payload->>'diesel_effective_from', '')::date, current_date) + freshness_days_value,
    false,
    jsonb_build_object(
      'source', 'pricing_settings_page',
      'display_source', 'Manual / live provider not configured',
      'live_provider_configured', false,
      'baseline_price_per_litre', baseline_price,
      'fuel_surcharge_enabled', coalesce(settings_payload->>'fuel_surcharge_enabled', 'true')
    )
  );
end;
$$;

create or replace function public.ttaq_save_pricing_settings(settings_payload jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_id uuid;
  vehicle_cost_id uuid;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules') then
    raise exception 'Not allowed to manage pricing settings';
  end if;

  profile_id := public.ttaq_active_pricing_profile();

  if profile_id is null then
    insert into public.pricing_profiles (name, is_active, currency, quote_validity_days, rule_version)
    values (
      coalesce(settings_payload->>'profile_name', 'Default configurable profile'),
      true,
      coalesce(settings_payload->>'currency', 'ZAR'),
      coalesce(nullif(settings_payload->>'quote_validity_days', '')::integer, 7),
      coalesce(settings_payload->>'rule_version', 'pricing-v3-automation')
    )
    returning id into profile_id;
  else
    update public.pricing_profiles
       set currency = coalesce(settings_payload->>'currency', currency),
           quote_validity_days = coalesce(nullif(settings_payload->>'quote_validity_days', '')::integer, quote_validity_days),
           rule_version = coalesce(settings_payload->>'rule_version', 'pricing-v3-automation')
     where id = profile_id;
  end if;

  insert into public.fuel_price_history (pricing_profile_id, fuel_price_per_litre, effective_from)
  values (
    profile_id,
    coalesce(nullif(settings_payload->>'fuel_price_per_litre', '')::numeric, 0),
    current_date
  );

  insert into public.diesel_price_integrations (
    pricing_profile_id,
    provider_name,
    provider_status,
    provider_price_per_litre,
    admin_override_price_per_litre,
    effective_from,
    source_type,
    source_url,
    freshness_days,
    next_expected_refresh,
    provider_response
  )
  values (
    profile_id,
    'manual_admin_override',
    'manual_fallback',
    null,
    coalesce(nullif(settings_payload->>'diesel_admin_override_price_per_litre', '')::numeric, nullif(settings_payload->>'fuel_price_per_litre', '')::numeric, 0),
    current_date,
    'manual_override',
    'https://www.dmpr.gov.za/Services/Petroleum-Resources/Fuel-Prices',
    greatest(coalesce(nullif(settings_payload->>'diesel_max_age_days', '')::integer, 35), 1),
    current_date + greatest(coalesce(nullif(settings_payload->>'diesel_max_age_days', '')::integer, 35), 1),
    jsonb_build_object('source', 'pricing_settings_page', 'display_source', 'Manual / live provider not configured', 'live_provider_configured', false)
  );

  insert into public.vehicle_operating_costs (
    pricing_profile_id,
    vehicle_type,
    trailer_type,
    fuel_consumption_l_per_100km,
    average_tyre_cost_per_km,
    maintenance_cost_per_km,
    insurance_cost_per_km,
    depreciation_cost_per_km,
    vehicle_overhead_per_km
  )
  values (
    profile_id,
    coalesce(nullif(settings_payload->>'vehicle_cost_profile_key', ''), 'default'),
    'default',
    coalesce(nullif(settings_payload->>'fuel_consumption_l_per_100km', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'average_tyre_cost_per_km', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'maintenance_cost_per_km', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'insurance_cost_per_km', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'depreciation_cost_per_km', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'vehicle_overhead_per_km', '')::numeric, 0)
  )
  on conflict (pricing_profile_id, vehicle_type, trailer_type) do update
  set fuel_consumption_l_per_100km = excluded.fuel_consumption_l_per_100km,
      average_tyre_cost_per_km = excluded.average_tyre_cost_per_km,
      maintenance_cost_per_km = excluded.maintenance_cost_per_km,
      insurance_cost_per_km = excluded.insurance_cost_per_km,
      depreciation_cost_per_km = excluded.depreciation_cost_per_km,
      vehicle_overhead_per_km = excluded.vehicle_overhead_per_km
  returning id into vehicle_cost_id;

  insert into public.vehicle_operating_costs (
    pricing_profile_id,
    vehicle_type,
    trailer_type,
    fuel_consumption_l_per_100km,
    average_tyre_cost_per_km,
    maintenance_cost_per_km,
    insurance_cost_per_km,
    depreciation_cost_per_km,
    vehicle_overhead_per_km
  )
  select profile_id, 'default', 'default',
    coalesce(nullif(settings_payload->>'fuel_consumption_l_per_100km', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'average_tyre_cost_per_km', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'maintenance_cost_per_km', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'insurance_cost_per_km', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'depreciation_cost_per_km', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'vehicle_overhead_per_km', '')::numeric, 0)
  where coalesce(nullif(settings_payload->>'vehicle_cost_profile_key', ''), 'default') <> 'default'
  on conflict (pricing_profile_id, vehicle_type, trailer_type) do update
  set fuel_consumption_l_per_100km = excluded.fuel_consumption_l_per_100km,
      average_tyre_cost_per_km = excluded.average_tyre_cost_per_km,
      maintenance_cost_per_km = excluded.maintenance_cost_per_km,
      insurance_cost_per_km = excluded.insurance_cost_per_km,
      depreciation_cost_per_km = excluded.depreciation_cost_per_km,
      vehicle_overhead_per_km = excluded.vehicle_overhead_per_km;

  insert into public.driver_costs (pricing_profile_id, driver_hourly_wage, driver_overnight_allowance)
  values (
    profile_id,
    coalesce(nullif(settings_payload->>'driver_hourly_wage', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'driver_overnight_allowance', '')::numeric, 0)
  );

  insert into public.company_overheads (
    pricing_profile_id,
    admin_overhead_percent,
    profit_margin_percent,
    vat_percent,
    minimum_profit,
    maximum_discount_percent
  )
  values (
    profile_id,
    coalesce(nullif(settings_payload->>'admin_overhead_percent', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'profit_margin_percent', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'vat_percent', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'minimum_profit', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'maximum_discount_percent', '')::numeric, 0)
  );

  update public.company_margin_profiles
     set is_default = false
   where pricing_profile_id = profile_id;

  insert into public.company_margin_profiles (
    pricing_profile_id,
    margin_key,
    display_name,
    margin_percent,
    minimum_profit,
    is_default,
    is_active,
    notes
  )
  values (
    profile_id,
    coalesce(nullif(settings_payload->>'margin_profile_key', ''), 'target'),
    initcap(coalesce(nullif(settings_payload->>'margin_profile_key', ''), 'target')) || ' margin',
    coalesce(nullif(settings_payload->>'margin_profile_percent', '')::numeric, nullif(settings_payload->>'profit_margin_percent', '')::numeric, 0),
    coalesce(nullif(settings_payload->>'margin_profile_minimum_profit', '')::numeric, nullif(settings_payload->>'minimum_profit', '')::numeric, 0),
    true,
    true,
    'Configured from pricing settings page'
  )
  on conflict (pricing_profile_id, margin_key) do update
  set margin_percent = excluded.margin_percent,
      minimum_profit = excluded.minimum_profit,
      is_default = true,
      is_active = true,
      notes = excluded.notes;

  insert into public.pricing_settings (pricing_profile_id, setting_key, setting_value, setting_unit, description)
  select profile_id, key, coalesce(nullif(value, '')::numeric, 0), 'currency', key
  from jsonb_each_text(coalesce(settings_payload->'surcharges', '{}'::jsonb))
  on conflict (pricing_profile_id, setting_key) do update
  set setting_value = excluded.setting_value;

  insert into public.pricing_settings (pricing_profile_id, setting_key, setting_value, setting_unit, description)
  values
    (profile_id, 'diesel_base_price_per_litre', coalesce(nullif(settings_payload->>'diesel_base_price_per_litre', '')::numeric, 24), 'ZAR/L', 'Baseline diesel price used for automatic fuel surcharge'),
    (profile_id, 'fuel_surcharge_enabled', case when coalesce(settings_payload->>'fuel_surcharge_enabled', 'true') in ('true', '1', 'on', 'yes') then 1 else 0 end, 'boolean', 'Enable automatic fuel surcharge calculation'),
    (profile_id, 'seasonal_low_multiplier', coalesce(nullif(settings_payload->>'seasonal_low_multiplier', '')::numeric, 0.95), 'multiplier', 'Low season multiplier'),
    (profile_id, 'seasonal_normal_multiplier', coalesce(nullif(settings_payload->>'seasonal_normal_multiplier', '')::numeric, 1.00), 'multiplier', 'Normal season multiplier'),
    (profile_id, 'seasonal_busy_multiplier', coalesce(nullif(settings_payload->>'seasonal_busy_multiplier', '')::numeric, 1.10), 'multiplier', 'Busy season multiplier'),
    (profile_id, 'seasonal_peak_multiplier', coalesce(nullif(settings_payload->>'seasonal_peak_multiplier', '')::numeric, 1.20), 'multiplier', 'Peak season multiplier'),
    (profile_id, 'default_toll_cost', coalesce(nullif(settings_payload->>'default_toll_cost', '')::numeric, 0), 'currency', 'Fallback toll framework amount'),
    (profile_id, 'default_route_risk_surcharge', coalesce(nullif(settings_payload->>'default_route_risk_surcharge', '')::numeric, 0), 'currency', 'Fallback route risk amount'),
    (profile_id, 'minimum_selling_price', coalesce(nullif(settings_payload->>'minimum_selling_price', '')::numeric, 0), 'ZAR', 'Optional minimum customer selling price floor'),
    (profile_id, 'minimum_margin_percent', coalesce(nullif(settings_payload->>'minimum_margin_percent', '')::numeric, 15), 'percent', 'Minimum acceptable margin warning threshold'),
    (profile_id, 'additional_stop_rate', coalesce(nullif(settings_payload->>'additional_stop_rate', '')::numeric, 0), 'ZAR/stop', 'Charge per additional stop beyond one collection and one delivery'),
    (profile_id, 'cross_border_surcharge', coalesce(nullif(settings_payload->>'cross_border_surcharge', '')::numeric, 0), 'ZAR', 'Commercial surcharge when cross-border movement is detected'),
    (profile_id, 'diesel_max_age_days', coalesce(nullif(settings_payload->>'diesel_max_age_days', '')::numeric, 35), 'days', 'Approved freshness period for cached diesel values'),
    (profile_id, 'toll_manual_review_required', case when coalesce(settings_payload->>'toll_manual_review_required', 'true') in ('true', '1', 'on', 'yes') then 1 else 0 end, 'boolean', 'Flag manual review when no trusted toll value exists')
  on conflict (pricing_profile_id, setting_key) do update
  set setting_value = excluded.setting_value,
      setting_unit = excluded.setting_unit,
      description = excluded.description;

  update public.pricing_seasonal_multipliers
     set multiplier = case season_key
       when 'low' then public.ttaq_pricing_setting(profile_id, 'seasonal_low_multiplier')
       when 'normal' then public.ttaq_pricing_setting(profile_id, 'seasonal_normal_multiplier')
       when 'busy' then public.ttaq_pricing_setting(profile_id, 'seasonal_busy_multiplier')
       when 'peak' then public.ttaq_pricing_setting(profile_id, 'seasonal_peak_multiplier')
       else multiplier
     end,
     is_active = true
   where pricing_profile_id = profile_id;

  return profile_id;
end;
$$;
