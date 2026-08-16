create table if not exists public.time_trucking_commercial_rate_card (
  id uuid primary key default gen_random_uuid(),
  pricing_profile_id uuid not null references public.pricing_profiles(id) on delete cascade,
  rate_category_key text not null,
  display_name text not null,
  hazardous boolean not null default false,
  day_rate numeric(12, 2) not null,
  per_km_rate numeric(12, 4) not null,
  axle_count_default integer,
  diesel_reference_price_per_litre numeric(12, 4),
  source_note text not null default 'Henning supplied Time Trucking commercial rate card',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (pricing_profile_id, rate_category_key, hazardous)
);

alter table public.time_trucking_commercial_rate_card enable row level security;

drop policy if exists "Internal users read commercial rate card" on public.time_trucking_commercial_rate_card;
create policy "Internal users read commercial rate card" on public.time_trucking_commercial_rate_card
for select using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));

drop policy if exists "Pricing managers manage commercial rate card" on public.time_trucking_commercial_rate_card;
create policy "Pricing managers manage commercial rate card" on public.time_trucking_commercial_rate_card
for all using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

insert into public.time_trucking_commercial_rate_card (
  pricing_profile_id,
  rate_category_key,
  display_name,
  hazardous,
  day_rate,
  per_km_rate,
  axle_count_default,
  diesel_reference_price_per_litre
)
select profile_id, rate_category_key, display_name, hazardous, day_rate, per_km_rate, axle_count_default, 26.4060
from public.ttaq_active_pricing_profile() profile_id
cross join (
  values
    ('1_ton', '1 Ton', false, 3000.00, 7.5000, 2),
    ('1_ton', '1 Ton HAZ', true, 3250.00, 7.5000, 2),
    ('1_8_ton', '1.8 Ton', false, 3250.00, 8.0000, 4),
    ('1_8_ton', '1.8 Ton HAZ', true, 3500.00, 8.5000, 4),
    ('3_ton', '3 Ton', false, 3500.00, 8.5000, 2),
    ('3_ton', '3 Ton HAZ', true, 3750.00, 8.5000, 2),
    ('5_ton', '5 Ton', false, 3750.00, 12.0000, 2),
    ('5_ton', '5 Ton HAZ', true, 4250.00, 12.0000, 2),
    ('8_ton', '8 Ton', false, 4250.00, 18.0000, 2),
    ('8_ton', '8 Ton HAZ', true, 4500.00, 18.0000, 2),
    ('12_ton', '12 Ton', false, 5250.00, 12.0000, 3),
    ('12_ton', '12 Ton HAZ', true, 5750.00, 12.0000, 3),
    ('semi', 'Semi', false, 8000.00, 18.0000, 9),
    ('semi', 'Semi HAZ', true, 8500.00, 18.0000, 9),
    ('superlink', 'S/L', false, 8500.00, 18.0000, 10),
    ('superlink', 'S/L HAZ', true, 9000.00, 18.0000, 10)
) as rates(rate_category_key, display_name, hazardous, day_rate, per_km_rate, axle_count_default)
where profile_id is not null
on conflict (pricing_profile_id, rate_category_key, hazardous) do update
set display_name = excluded.display_name,
    day_rate = excluded.day_rate,
    per_km_rate = excluded.per_km_rate,
    axle_count_default = excluded.axle_count_default,
    diesel_reference_price_per_litre = excluded.diesel_reference_price_per_litre,
    source_note = excluded.source_note,
    is_active = true,
    updated_at = now();

insert into public.pricing_settings (pricing_profile_id, setting_key, setting_value)
select profile_id, setting_key, setting_value
from public.ttaq_active_pricing_profile() profile_id
cross join (
  values
    ('additional_stop_rate', 1500.0000),
    ('commercial_rate_basis_rule', 0.0000),
    ('commercial_chargeable_day_count_default', 1.0000),
    ('night_out_rate', 1750.0000),
    ('night_out_count_default', 0.0000),
    ('diesel_selling_adjustment_enabled', 0.0000),
    ('commercial_additional_margin_percent', 0.0000),
    ('commercial_10_percent_protection_enabled', 0.0000)
) as settings(setting_key, setting_value)
where profile_id is not null
on conflict (pricing_profile_id, setting_key) do update
set setting_value = excluded.setting_value,
    updated_at = now();

update public.driver_costs
   set driver_overnight_allowance = 1750.00,
       updated_at = now()
 where pricing_profile_id = public.ttaq_active_pricing_profile();

update public.pricing_profiles
   set rule_version = 'pricing-v3-commercial-rate-card',
       updated_at = now()
 where id = public.ttaq_active_pricing_profile();

create or replace function public.ttaq_commercial_rate_category_for_equipment(equipment_code_value text, display_name_value text)
returns text
language sql
immutable
as $$
  select case
    when lower(coalesce(equipment_code_value, display_name_value, '')) like '%bakkie%'
      or lower(coalesce(display_name_value, '')) like '%1-ton%' then '1_ton'
    when lower(coalesce(equipment_code_value, display_name_value, '')) like '%8t%'
      or lower(coalesce(display_name_value, '')) like '%8-ton%' then '8_ton'
    when lower(coalesce(equipment_code_value, display_name_value, '')) like '%tri-axle%'
      or lower(coalesce(display_name_value, '')) like '%tri-axle%' then 'semi'
    when lower(coalesce(equipment_code_value, display_name_value, '')) like '%superlink%'
      or lower(coalesce(display_name_value, '')) like '%superlink%' then 'superlink'
    else null
  end;
$$;

comment on function public.ttaq_commercial_rate_category_for_equipment(text, text) is
  'Maps deployed equipment profiles to Henning supplied Time Trucking commercial rate-card categories. Unmapped categories require management review rather than guessed pricing.';

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
  diesel_record record;
  season_record record;
  rate_record public.time_trucking_commercial_rate_card%rowtype;
  fuel_price numeric := 0;
  diesel_base_price numeric := 0;
  diesel_variance_amount numeric := 0;
  diesel_variance_percent numeric := 0;
  seasonal_key text := 'normal';
  seasonal_multiplier_value numeric := 1;
  total_weight numeric := 0;
  total_volume numeric := 0;
  total_value numeric := 0;
  unit_count numeric := 1;
  additional_stop_count integer := 0;
  additional_stop_amount numeric := 0;
  cross_border_detected boolean := false;
  cross_border_amount numeric := 0;
  night_out_count numeric := 0;
  night_out_rate numeric := 0;
  night_out_amount numeric := 0;
  commercial_rate_basis_rule numeric := 0;
  chargeable_day_count numeric := 1;
  commercial_per_km_amount numeric := 0;
  commercial_per_day_amount numeric := 0;
  commercial_base_amount numeric := 0;
  diesel_selling_adjustment_amount numeric := 0;
  fuel_amount numeric := 0;
  tyres_amount numeric := 0;
  maintenance_amount numeric := 0;
  insurance_amount numeric := 0;
  depreciation_amount numeric := 0;
  driver_amount numeric := 0;
  vehicle_overhead_amount numeric := 0;
  internal_operating_cost numeric := 0;
  estimated_contribution numeric := 0;
  escort_amount numeric := 0;
  permit_amount numeric := 0;
  hazmat_amount numeric := 0;
  refrigeration_amount numeric := 0;
  crane_amount numeric := 0;
  forklift_amount numeric := 0;
  high_value_amount numeric := 0;
  toll_amount numeric := 0;
  route_risk_amount numeric := 0;
  seasonal_amount numeric := 0;
  subtotal_value numeric := 0;
  vat_value numeric := 0;
  grand_total_value numeric := 0;
  minimum_margin_percent numeric := 0;
  calculation_id uuid;
  currency_value text := 'ZAR';
  rule_version_value text := 'pricing-v3-commercial-rate-card';
  route_text text := '';
  route_review_required boolean := false;
  hazmat_required boolean := false;
  rate_category_value text;
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

  if request_record.id is null then
    raise exception 'Quote request not found';
  end if;

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
         coalesce(sum(coalesce(cargo_value, 0)), 0),
         coalesce(bool_or(coalesce(dangerous_goods, false) or cargo_category::text = 'dangerous_goods'), false)
    into total_weight, total_volume, total_value, hazmat_required
  from public.quote_items
  where quote_request_id = target_quote_request_id;

  hazmat_required := coalesce(hazmat_required, false) or coalesce(recommendation.hazmat_required, false);

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

  select * into season_record
  from public.ttaq_active_seasonal_multiplier_for_date(profile_id, coalesce(request_record.collection_date, current_date));

  seasonal_key := coalesce(season_record.season_key, 'normal');
  seasonal_multiplier_value := coalesce(season_record.multiplier, public.ttaq_pricing_setting(profile_id, 'seasonal_normal_multiplier'), 1);

  select * into diesel_record
  from public.ttaq_current_diesel_input(profile_id);

  fuel_price := coalesce(diesel_record.price_per_litre, 0);
  diesel_base_price := coalesce(nullif(public.ttaq_pricing_setting(profile_id, 'diesel_base_price_per_litre'), 0), 26.4060);
  diesel_variance_amount := round(fuel_price - diesel_base_price, 4);
  diesel_variance_percent := case when diesel_base_price > 0 then round(((fuel_price - diesel_base_price) / diesel_base_price) * 100, 4) else 0 end;

  unit_count := greatest(1, coalesce(recommendation.number_of_trucks, 1));
  commercial_rate_basis_rule := public.ttaq_pricing_setting(profile_id, 'commercial_rate_basis_rule');
  chargeable_day_count := greatest(1, coalesce(nullif(public.ttaq_pricing_setting(profile_id, 'commercial_chargeable_day_count_default'), 0), 1));
  night_out_count := greatest(0, coalesce(public.ttaq_pricing_setting(profile_id, 'night_out_count_default'), 0));
  night_out_rate := coalesce(nullif(public.ttaq_pricing_setting(profile_id, 'night_out_rate'), 0), 1750);
  additional_stop_amount := additional_stop_count * public.ttaq_pricing_setting(profile_id, 'additional_stop_rate');
  night_out_amount := night_out_count * unit_count * night_out_rate;
  cross_border_amount := case when cross_border_detected then public.ttaq_pricing_setting(profile_id, 'cross_border_surcharge') else 0 end;

  rate_category_value := public.ttaq_commercial_rate_category_for_equipment(selected_equipment.equipment_code, selected_equipment.display_name);

  select * into rate_record
  from public.time_trucking_commercial_rate_card
  where pricing_profile_id = profile_id
    and rate_category_key = rate_category_value
    and hazardous = hazmat_required
    and is_active
  limit 1;

  if rate_record.id is null and rate_category_value is not null then
    select * into rate_record
    from public.time_trucking_commercial_rate_card
    where pricing_profile_id = profile_id
      and rate_category_key = rate_category_value
      and hazardous = false
      and is_active
    limit 1;
  end if;

  commercial_per_km_amount := round(coalesce(estimated_distance_km, 0) * unit_count * coalesce(rate_record.per_km_rate, 0), 2);
  commercial_per_day_amount := round(chargeable_day_count * unit_count * coalesce(rate_record.day_rate, 0), 2);
  commercial_base_amount := case
    when commercial_rate_basis_rule = 1 then commercial_per_km_amount
    when commercial_rate_basis_rule = 2 then commercial_per_day_amount
    else 0
  end;

  diesel_selling_adjustment_amount := 0;

  fuel_amount := round(coalesce(estimated_distance_km, 0) * unit_count * (coalesce(selected_equipment.fuel_consumption_l_per_100km, vehicle_cost.fuel_consumption_l_per_100km, 0) / 100) * fuel_price, 2);
  tyres_amount := round(coalesce(estimated_distance_km, 0) * unit_count * coalesce(selected_equipment.average_tyre_cost_per_km, vehicle_cost.average_tyre_cost_per_km, 0), 2);
  maintenance_amount := round(coalesce(estimated_distance_km, 0) * unit_count * coalesce(selected_equipment.maintenance_cost_per_km, vehicle_cost.maintenance_cost_per_km, 0), 2);
  insurance_amount := round(coalesce(estimated_distance_km, 0) * unit_count * coalesce(selected_equipment.insurance_cost_per_km, vehicle_cost.insurance_cost_per_km, 0), 2);
  depreciation_amount := round(coalesce(estimated_distance_km, 0) * unit_count * coalesce(selected_equipment.depreciation_cost_per_km, vehicle_cost.depreciation_cost_per_km, 0), 2);
  driver_amount := round(coalesce(estimated_duration_hours, 0) * unit_count * coalesce(driver_cost.driver_hourly_wage, 0), 2);
  vehicle_overhead_amount := round(coalesce(estimated_distance_km, 0) * unit_count * coalesce(selected_equipment.vehicle_overhead_per_km, vehicle_cost.vehicle_overhead_per_km, 0), 2);
  internal_operating_cost := fuel_amount + tyres_amount + maintenance_amount + insurance_amount + depreciation_amount + driver_amount + vehicle_overhead_amount;

  escort_amount := case when coalesce(recommendation.escort_recommended, false) then public.ttaq_pricing_setting(profile_id, 'escort_surcharge') else 0 end;
  permit_amount := case when coalesce(recommendation.permit_required, false) then public.ttaq_pricing_setting(profile_id, 'permit_surcharge') else 0 end;
  hazmat_amount := 0;
  refrigeration_amount := case when coalesce(recommendation.refrigeration_required, false) then public.ttaq_pricing_setting(profile_id, 'refrigeration_surcharge') else 0 end;
  crane_amount := case when coalesce(recommendation.crane_required, false) then public.ttaq_pricing_setting(profile_id, 'crane_surcharge') else 0 end;
  forklift_amount := case when coalesce(recommendation.forklift_required, false) then public.ttaq_pricing_setting(profile_id, 'forklift_surcharge') else 0 end;
  high_value_amount := case when total_value >= public.ttaq_pricing_setting(profile_id, 'high_value_threshold') and public.ttaq_pricing_setting(profile_id, 'high_value_threshold') > 0 then public.ttaq_pricing_setting(profile_id, 'high_value_surcharge') else 0 end;

  subtotal_value := commercial_base_amount + diesel_selling_adjustment_amount + additional_stop_amount + night_out_amount + cross_border_amount + escort_amount + permit_amount + hazmat_amount + refrigeration_amount + crane_amount + forklift_amount + high_value_amount + toll_amount + route_risk_amount;
  seasonal_amount := round(subtotal_value * (seasonal_multiplier_value - 1), 2);
  subtotal_value := round(subtotal_value + seasonal_amount, 2);
  vat_value := round(subtotal_value * (coalesce(overhead.vat_percent, 0) / 100), 2);
  grand_total_value := subtotal_value + vat_value;
  estimated_contribution := round(subtotal_value - internal_operating_cost, 2);
  minimum_margin_percent := public.ttaq_pricing_setting(profile_id, 'minimum_margin_percent');

  select currency into currency_value
  from public.pricing_profiles
  where id = profile_id;

  source_snapshot := jsonb_build_object(
    'commercial', jsonb_build_object(
      'methodology', 'Time Trucking commercial rate card is the primary customer selling-price basis',
      'rate_card_id', rate_record.id,
      'rate_category_key', rate_category_value,
      'rate_display_name', rate_record.display_name,
      'hazardous_rate', hazmat_required,
      'day_rate', rate_record.day_rate,
      'per_km_rate', rate_record.per_km_rate,
      'per_km_scenario_amount', commercial_per_km_amount,
      'per_day_scenario_amount', commercial_per_day_amount,
      'selected_basis_rule', commercial_rate_basis_rule,
      'selected_base_amount', commercial_base_amount,
      'basis_warning', case when commercial_rate_basis_rule not in (1, 2) then 'DAY VS KM PRICING RULE REQUIRES HENNING CONFIRMATION' else null end,
      'normal_profit', 'Included in Henning commercial rate',
      'additional_margin_percent', 0,
      'ten_percent_protection', 'Pending exact Time Trucking definition',
      'pricing_order', jsonb_build_array(
        'approved_time_trucking_commercial_base_rate',
        'approved_diesel_adjustment_if_configured',
        'tolls',
        'additional_stops',
        'night_out_allowance',
        'approved_cross_border_charge',
        'approved_route_risk_charge',
        'approved_seasonal_adjustment',
        'approved_special_requirement_charges',
        'vat'
      )
    ),
    'internal_cost_analysis', jsonb_build_object(
      'fuel_amount', fuel_amount,
      'tyres_amount', tyres_amount,
      'maintenance_amount', maintenance_amount,
      'vehicle_insurance_amount', insurance_amount,
      'depreciation_amount', depreciation_amount,
      'driver_amount', driver_amount,
      'vehicle_overhead_amount', vehicle_overhead_amount,
      'estimated_internal_operating_cost', internal_operating_cost,
      'estimated_contribution_before_vat', estimated_contribution,
      'selling_price_effect', 'Internal operating costs do not increase the customer selling price'
    ),
    'diesel', diesel_record.source_payload || jsonb_build_object(
      'reference_price_per_litre', diesel_base_price,
      'current_price_per_litre', fuel_price,
      'variance_amount_per_litre', diesel_variance_amount,
      'variance_percent', diesel_variance_percent,
      'selling_price_diesel_adjustment', diesel_selling_adjustment_amount,
      'selling_price_diesel_adjustment_status', 'Pending approved rule'
    ),
    'route', jsonb_build_object(
      'distance_km', estimated_distance_km,
      'duration_hours', estimated_duration_hours,
      'source', coalesce(route_record.provider_name, 'manual_or_unavailable'),
      'provider_status', route_record.provider_status,
      'calculated_at', route_record.estimated_at
    ),
    'tolls', jsonb_build_object(
      'amount', toll_amount,
      'source', 'pending_official_toll_finalisation',
      'provider_toll_status', coalesce(route_record.toll_status, route_record.provider_response->>'toll_status'),
      'review_warning', 'TOLL PRICING REQUIRES REVIEW unless official toll finalisation attaches a reliable tariff result'
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
      'equipment_code', selected_equipment.equipment_code,
      'rate_category_key', rate_category_value,
      'unit_count', unit_count,
      'equipment_source', recommendation.equipment_source
    )
  );

  automation_status_value := jsonb_build_object(
    'diesel_requires_review', coalesce(diesel_record.requires_review, true),
    'diesel_selling_adjustment_requires_rule', true,
    'route_requires_review', coalesce(estimated_distance_km, 0) <= 0,
    'toll_requires_review', true,
    'day_vs_km_rule_requires_confirmation', commercial_rate_basis_rule not in (1, 2),
    'rate_card_mapping_requires_review', rate_record.id is null,
    'night_out_count_requires_confirmation', true,
    'ten_percent_protection_requires_confirmation', true,
    'cross_border_detected', cross_border_detected,
    'additional_stop_count', additional_stop_count,
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
    target_quote_request_id, recommendation.id, profile_id, rule_version_value,
    coalesce(estimated_distance_km, 0), coalesce(estimated_duration_hours, 0), total_weight, total_volume,
    subtotal_value, 0, vat_value, grand_total_value, grand_total_value,
    coalesce(currency_value, 'ZAR'),
    'Commercial pricing generated from Henning supplied Time Trucking rate card. Internal operating costs are retained for profitability analysis only and are not stacked onto the customer selling price.',
    fuel_price, 0, seasonal_multiplier_value, seasonal_amount, toll_amount, route_risk_amount,
    'commercial_rate_card', 0,
    source_snapshot,
    jsonb_build_object(
      'vehicle_dependent_costs_multiplier', unit_count,
      'commercial_rate_basis_rule', commercial_rate_basis_rule,
      'commercial_chargeable_day_count', chargeable_day_count,
      'commercial_per_km_amount', commercial_per_km_amount,
      'commercial_per_day_amount', commercial_per_day_amount,
      'commercial_base_amount', commercial_base_amount,
      'diesel_reference_price_per_litre', diesel_base_price,
      'diesel_current_price_per_litre', fuel_price,
      'diesel_variance_amount_per_litre', diesel_variance_amount,
      'diesel_variance_percent', diesel_variance_percent,
      'diesel_selling_adjustment_amount', diesel_selling_adjustment_amount,
      'additional_stop_amount', additional_stop_amount,
      'night_out_count', night_out_count,
      'night_out_rate', night_out_rate,
      'night_out_amount', night_out_amount,
      'cross_border_amount', cross_border_amount,
      'shipment_level_surcharges', escort_amount + permit_amount + hazmat_amount + refrigeration_amount + crane_amount + forklift_amount + high_value_amount + additional_stop_amount + cross_border_amount + night_out_amount,
      'base_cost_before_seasonal', subtotal_value - seasonal_amount,
      'toll_amount', toll_amount,
      'route_risk_amount', route_risk_amount,
      'seasonal_amount', seasonal_amount,
      'company_overhead_amount', 0,
      'profit_amount', 0,
      'expected_margin_percent', 0,
      'vat_amount', vat_value,
      'grand_total', grand_total_value,
      'fuel_amount', fuel_amount,
      'tyres_amount', tyres_amount,
      'maintenance_amount', maintenance_amount,
      'vehicle_insurance_amount', insurance_amount,
      'depreciation_amount', depreciation_amount,
      'driver_amount', driver_amount,
      'internal_vehicle_overhead_amount', vehicle_overhead_amount,
      'estimated_internal_operating_cost', internal_operating_cost,
      'estimated_contribution_before_vat', estimated_contribution,
      'normal_profit_status', 'Included in Henning commercial rate',
      'ten_percent_protection_status', 'Pending exact Time Trucking definition'
    ),
    true
      or coalesce(route_review_required, false)
      or coalesce(recommendation.manager_review_required, false)
      or coalesce(diesel_record.requires_review, true)
      or coalesce(estimated_distance_km, 0) <= 0
      or rate_record.id is null,
    source_snapshot,
    automation_status_value
  )
  returning id into calculation_id;

  insert into public.pricing_breakdowns (pricing_calculation_id, quote_request_id, line_key, line_label, quantity, unit_rate, amount, explanation)
  values
    (calculation_id, target_quote_request_id, 'commercial_per_km_scenario', 'Commercial base - per-km scenario', coalesce(estimated_distance_km, 0) * unit_count, coalesce(rate_record.per_km_rate, 0), commercial_per_km_amount, 'Commercial selling-price scenario only: route distance x Time Trucking rate-card R/km x unit count. Not automatically selected until Henning confirms day-vs-km rule.'),
    (calculation_id, target_quote_request_id, 'commercial_per_day_scenario', 'Commercial base - per-day scenario', chargeable_day_count * unit_count, coalesce(rate_record.day_rate, 0), commercial_per_day_amount, 'Commercial selling-price scenario only: chargeable day count x Time Trucking rate-card R/day x unit count. Chargeable day rule requires confirmation.'),
    (calculation_id, target_quote_request_id, 'commercial_base', 'Selected commercial base', case when commercial_rate_basis_rule in (1, 2) then 1 else 0 end, commercial_base_amount, commercial_base_amount, 'Authoritative customer selling-price base. Zero and review-required while DAY VS KM PRICING RULE REQUIRES HENNING CONFIRMATION.'),
    (calculation_id, target_quote_request_id, 'diesel_selling_adjustment', 'Diesel selling-price adjustment', diesel_variance_amount, 0, diesel_selling_adjustment_amount, 'Reference diesel and current official diesel variance is shown for audit. Selling-price diesel adjustment is inactive pending approved Time Trucking formula.'),
    (calculation_id, target_quote_request_id, 'additional_stops', 'Additional stops', additional_stop_count, public.ttaq_pricing_setting(profile_id, 'additional_stop_rate'), additional_stop_amount, 'Additional collection/delivery stops beyond initial collection and final delivery x Time Trucking R1,500 rate.'),
    (calculation_id, target_quote_request_id, 'night_out', 'Night-out allowance', night_out_count * unit_count, night_out_rate, night_out_amount, 'Explicit night_out_count x vehicle/unit count x Time Trucking R1,750 allowance. Automatic trigger requires Henning confirmation.'),
    (calculation_id, target_quote_request_id, 'cross_border', 'Cross-border', case when cross_border_detected then 1 else 0 end, public.ttaq_pricing_setting(profile_id, 'cross_border_surcharge'), cross_border_amount, 'Approved cross-border charge only if configured; cross-border detection is captured separately.'),
    (calculation_id, target_quote_request_id, 'tolls', 'Tolls', coalesce(estimated_distance_km, 0), toll_amount, toll_amount, 'TOLL PRICING REQUIRES REVIEW unless official toll finalisation attaches a reliable tariff result.'),
    (calculation_id, target_quote_request_id, 'route_risk', 'Route risk', subtotal_value - seasonal_amount, 0, route_risk_amount, 'Approved route-risk policy charge only; no unapproved high-risk values are invented.'),
    (calculation_id, target_quote_request_id, 'seasonal_multiplier', 'Seasonal multiplier', subtotal_value - seasonal_amount, seasonal_multiplier_value, seasonal_amount, 'Approved seasonal multiplier selected from collection date when configured.'),
    (calculation_id, target_quote_request_id, 'escort', 'Escort', 1, escort_amount, escort_amount, 'Approved escort surcharge when recommended.'),
    (calculation_id, target_quote_request_id, 'permit', 'Permit', 1, permit_amount, permit_amount, 'Approved permit surcharge when required.'),
    (calculation_id, target_quote_request_id, 'hazmat', 'Hazmat surcharge', 1, 0, hazmat_amount, 'HAZ uses the HAZ commercial rate-card row. Generic hazmat surcharge is not stacked on top.'),
    (calculation_id, target_quote_request_id, 'refrigeration', 'Refrigeration', 1, refrigeration_amount, refrigeration_amount, 'Approved refrigeration surcharge when required.'),
    (calculation_id, target_quote_request_id, 'crane', 'Crane', 1, crane_amount, crane_amount, 'Approved crane surcharge when required.'),
    (calculation_id, target_quote_request_id, 'forklift', 'Forklift', 1, forklift_amount, forklift_amount, 'Approved forklift surcharge when required.'),
    (calculation_id, target_quote_request_id, 'high_value', 'High-value cargo', 1, high_value_amount, high_value_amount, 'Approved high-value surcharge when cargo value exceeds configured threshold.'),
    (calculation_id, target_quote_request_id, 'overhead', 'Company overhead', subtotal_value, 0, 0, 'Normal company overhead is treated as included in the commercial rate unless an approved Time Trucking rule is configured.'),
    (calculation_id, target_quote_request_id, 'profit', 'Normal profit', subtotal_value, 0, 0, 'Normal profit is included in Henning commercial rate. Additional margin is 0%; 10% protection pending exact Time Trucking definition.'),
    (calculation_id, target_quote_request_id, 'vat', 'VAT', subtotal_value, coalesce(overhead.vat_percent, 0), vat_value, 'VAT applied to commercial subtotal at configured VAT percent.'),
    (calculation_id, target_quote_request_id, 'internal_fuel', 'Internal cost - fuel', coalesce(estimated_distance_km, 0) * unit_count, fuel_price, fuel_amount, 'Internal operating-cost analysis only: distance x selected equipment fuel consumption x current diesel price x unit count. Does not alter customer selling price.'),
    (calculation_id, target_quote_request_id, 'internal_tyres', 'Internal cost - tyres', coalesce(estimated_distance_km, 0) * unit_count, coalesce(selected_equipment.average_tyre_cost_per_km, vehicle_cost.average_tyre_cost_per_km, 0), tyres_amount, 'Internal operating-cost analysis only. Does not alter customer selling price.'),
    (calculation_id, target_quote_request_id, 'internal_maintenance', 'Internal cost - maintenance', coalesce(estimated_distance_km, 0) * unit_count, coalesce(selected_equipment.maintenance_cost_per_km, vehicle_cost.maintenance_cost_per_km, 0), maintenance_amount, 'Internal operating-cost analysis only. Does not alter customer selling price.'),
    (calculation_id, target_quote_request_id, 'internal_insurance', 'Internal cost - insurance', coalesce(estimated_distance_km, 0) * unit_count, coalesce(selected_equipment.insurance_cost_per_km, vehicle_cost.insurance_cost_per_km, 0), insurance_amount, 'Internal operating-cost analysis only. Does not alter customer selling price.'),
    (calculation_id, target_quote_request_id, 'internal_depreciation', 'Internal cost - depreciation', coalesce(estimated_distance_km, 0) * unit_count, coalesce(selected_equipment.depreciation_cost_per_km, vehicle_cost.depreciation_cost_per_km, 0), depreciation_amount, 'Internal operating-cost analysis only. Does not alter customer selling price.'),
    (calculation_id, target_quote_request_id, 'internal_driver', 'Internal cost - driver', coalesce(estimated_duration_hours, 0) * unit_count, coalesce(driver_cost.driver_hourly_wage, 0), driver_amount, 'Internal operating-cost analysis only. Normal driver cost is not stacked on the commercial rate.'),
    (calculation_id, target_quote_request_id, 'internal_vehicle_overhead', 'Internal cost - vehicle overhead', coalesce(estimated_distance_km, 0) * unit_count, coalesce(selected_equipment.vehicle_overhead_per_km, vehicle_cost.vehicle_overhead_per_km, 0), vehicle_overhead_amount, 'Internal operating-cost analysis only. Vehicle overhead is not stacked on the commercial rate.');

  insert into public.pricing_calculation_audit_events (quote_request_id, pricing_calculation_id, event_type, event_payload, created_by)
  values (
    target_quote_request_id,
    calculation_id,
    'commercial_rate_card_price_generated',
    jsonb_build_object(
      'rule_version', rule_version_value,
      'recommended_selling_price', grand_total_value,
      'commercial_per_km_scenario', commercial_per_km_amount,
      'commercial_per_day_scenario', commercial_per_day_amount,
      'source_snapshot', source_snapshot,
      'automation_status', automation_status_value,
      'manager_review_required', true
    ),
    auth.uid()
  );

  update public.quote_requests
     set adjusted_price = grand_total_value
   where id = target_quote_request_id;

  return calculation_id;
end;
$$;

comment on function public.ttaq_generate_price(uuid, numeric, numeric) is
  'Authoritative new-quote pricing path. Customer selling price is based on Henning supplied Time Trucking commercial rate card plus only approved trip/business charges. Operating costs remain internal profitability analysis only.';
