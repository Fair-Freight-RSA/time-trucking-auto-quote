create table if not exists public.standard_equipment_profiles (
  id uuid primary key default gen_random_uuid(),
  equipment_code text not null unique,
  display_name text not null,
  vehicle_class text not null,
  trailer_body text not null,
  payload_capacity_kg numeric(12, 2),
  usable_cube_m3 numeric(12, 3),
  deck_length_m numeric(10, 3),
  deck_width_m numeric(10, 3),
  usable_deck_area_m2 numeric(12, 3),
  typical_pallet_capacity integer,
  enclosed boolean not null default false,
  open_deck boolean not null default false,
  side_loading boolean not null default false,
  rear_loading boolean not null default true,
  refrigerated boolean not null default false,
  specialist_abnormal boolean not null default false,
  fuel_consumption_l_per_100km numeric(14, 4) not null default 0,
  average_tyre_cost_per_km numeric(14, 4) not null default 0,
  maintenance_cost_per_km numeric(14, 4) not null default 0,
  insurance_cost_per_km numeric(14, 4) not null default 0,
  depreciation_cost_per_km numeric(14, 4) not null default 0,
  vehicle_overhead_per_km numeric(14, 4) not null default 0,
  equipment_source_default text not null default 'either',
  recommendation_priority integer not null default 100,
  is_active boolean not null default true,
  notes text,
  source_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint standard_equipment_source_check check (equipment_source_default in ('own_fleet', 'subcontractor', 'either'))
);

create trigger ttaq_standard_equipment_profiles_touch_updated_at
before update on public.standard_equipment_profiles
for each row execute function public.ttaq_touch_updated_at();

alter table public.standard_equipment_profiles enable row level security;

create policy "Internal users read standard equipment profiles"
on public.standard_equipment_profiles
for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Owner manages standard equipment profiles"
on public.standard_equipment_profiles
for all
using (
  public.ttaq_internal_user_role(auth.uid()) = 'owner'
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules')
)
with check (
  public.ttaq_internal_user_role(auth.uid()) = 'owner'
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules')
);

alter table public.vehicle_recommendations
  add column if not exists system_equipment_profile_id uuid references public.standard_equipment_profiles(id) on delete set null,
  add column if not exists final_equipment_profile_id uuid references public.standard_equipment_profiles(id) on delete set null,
  add column if not exists equipment_source text not null default 'either',
  add column if not exists equipment_alternatives jsonb not null default '[]'::jsonb,
  add column if not exists estimated_deck_utilization_percent numeric(7, 2),
  add column if not exists recommendation_reasoning jsonb not null default '[]'::jsonb,
  add column if not exists reset_to_system_at timestamptz,
  add constraint vehicle_recommendations_equipment_source_check check (equipment_source in ('own_fleet', 'subcontractor', 'either'));

create index if not exists ttaq_standard_equipment_profiles_active_priority_idx
  on public.standard_equipment_profiles(is_active, recommendation_priority);

create index if not exists ttaq_vehicle_recommendations_final_equipment_profile_idx
  on public.vehicle_recommendations(final_equipment_profile_id);

insert into public.standard_equipment_profiles (
  equipment_code,
  display_name,
  vehicle_class,
  trailer_body,
  payload_capacity_kg,
  usable_cube_m3,
  deck_length_m,
  deck_width_m,
  usable_deck_area_m2,
  typical_pallet_capacity,
  enclosed,
  open_deck,
  side_loading,
  rear_loading,
  refrigerated,
  specialist_abnormal,
  fuel_consumption_l_per_100km,
  average_tyre_cost_per_km,
  maintenance_cost_per_km,
  insurance_cost_per_km,
  depreciation_cost_per_km,
  vehicle_overhead_per_km,
  equipment_source_default,
  recommendation_priority,
  notes,
  source_note
)
values
  ('bakkie-panel-1t', '1-ton bakkie / panel van', 'small', 'Closed body', 1000, 6, 3.0, 1.6, 4.8, 2, true, false, false, true, false, false, 12, 0.9, 1.2, 0.45, 0.9, 0.8, 'either', 10, 'Small urgent freight and light pallet loads.', 'Commercial class seeded from existing Time Trucking data and Namcon light/small vehicle fleet examples.'),
  ('rigid-4t-curtain', '4-ton rigid curtainsider', 'rigid', 'Curtain side body', 4000, 22, 6.0, 2.3, 13.8, 8, true, false, true, true, false, false, 18, 1.2, 2.0, 0.7, 1.3, 1.2, 'either', 20, 'Regional small/medium palletised freight with side access.', 'Commercial class seeded from existing Time Trucking data and Namcon 4-8 ton vehicle examples.'),
  ('rigid-8t-tautliner', '8-ton rigid tautliner', 'rigid', 'Tautliner', 8000, 45, 7.2, 2.45, 17.64, 10, true, false, true, true, false, false, 24, 1.8, 3.5, 1.2, 2.5, 2.0, 'either', 30, 'Heavier regional palletised freight requiring weather protection.', 'Commercial class seeded from existing Time Trucking 8-ton data and industry 4-8 ton examples.'),
  ('tri-axle-tautliner', 'Horse + tri-axle tautliner', 'articulated', 'Tautliner', 28000, 85, 13.5, 2.48, 33.48, 26, true, false, true, true, false, false, 32, 2.6, 4.4, 1.5, 3.1, 2.7, 'either', 40, 'Normal commercial linehaul tautliner/curtainsider option.', 'Payload/cube aligned to DSV reefer dimensions/capacity and Namcon tri-axle tautliner loading-capacity examples; operational values remain configurable.'),
  ('tri-axle-flatdeck', 'Horse + tri-axle flatdeck', 'articulated', 'Flatdeck / tri-axle', 28000, 80, 13.5, 2.48, 33.48, 24, false, true, true, true, false, false, 33, 2.8, 4.6, 1.6, 3.3, 2.9, 'either', 50, 'Open-deck option for machinery, crane loading, and irregular freight.', 'Payload and deck profile aligned to South African tri-axle flatbed/operator examples; operational values remain configurable.'),
  ('superlink-tautliner', 'Superlink tautliner', 'superlink', 'Superlink tautliner', 34000, 100, 18.0, 2.48, 44.64, 34, true, false, true, true, false, false, 38, 3.1, 5.2, 1.9, 3.8, 3.4, 'either', 60, 'Large standard commercial palletised/general freight combination.', 'Payload/loading-space aligned to Namcon and Wallace Logistics superlink tautliner examples; operational values remain configurable.'),
  ('superlink-flatdeck', 'Superlink flatdeck', 'superlink', 'Superlink flatdeck', 34000, 95, 18.0, 2.48, 44.64, 32, false, true, true, true, false, false, 39, 3.2, 5.4, 2.0, 4.0, 3.6, 'either', 70, 'Large open-deck commercial freight combination.', 'Payload/loading-space aligned to South African superlink operator examples; operational values remain configurable.'),
  ('reefer-trailer', 'Refrigerated reefer trailer', 'articulated', 'Refrigerated trailer', 31000, 85, 13.31, 2.48, 33.01, 24, true, false, false, true, true, false, 40, 3.2, 5.8, 2.4, 4.2, 4.0, 'either', 80, 'Temperature-controlled linehaul equipment.', 'DSV South Africa reefer trailer reference: 31,000 kg payload, 85 m3 cube, 13.31m x 2.48m x 2.60m internal dimensions.'),
  ('container-skeletal', 'Container skeletal trailer', 'articulated', 'Skeletal trailer', 30000, 76, 12.2, 2.44, 29.77, null, false, true, false, true, false, false, 36, 3.0, 5.0, 1.8, 3.6, 3.2, 'subcontractor', 90, 'Container-focused equipment when container movement is indicated.', 'Common South African skeletal trailer category; exact payload must be confirmed per operator/container.'),
  ('lowbed-30t', '30-ton lowbed', 'specialist', 'Lowbed', 29350, 70, 9.0, 2.55, 22.95, null, false, true, true, true, false, true, 45, 4.0, 7.0, 2.8, 5.5, 5.0, 'subcontractor', 200, 'Specialist lowbed for machinery/oversized equipment; not normal pallet freight.', 'Afrit 30-ton lowbed reference lists approx. 29,350 kg payload; specialist abnormal/lowbed suitability remains manager-reviewed.'),
  ('heavy-haul-specialist', 'Heavy haul / abnormal specialist', 'specialist', 'Specialist abnormal trailer', 55000, 70, 18.0, 3.0, 54.0, null, false, true, true, true, false, true, 60, 5.0, 9.0, 4.0, 7.5, 7.0, 'subcontractor', 300, 'Specialist abnormal category for dimensions or mass outside normal configured commercial profiles.', 'Afrit/lowbed industry references describe abnormal/specialist lowbed capacity bands; exact permit/legal assessment remains manager-reviewed.')
on conflict (equipment_code) do update
set display_name = excluded.display_name,
    vehicle_class = excluded.vehicle_class,
    trailer_body = excluded.trailer_body,
    payload_capacity_kg = excluded.payload_capacity_kg,
    usable_cube_m3 = excluded.usable_cube_m3,
    deck_length_m = excluded.deck_length_m,
    deck_width_m = excluded.deck_width_m,
    usable_deck_area_m2 = excluded.usable_deck_area_m2,
    typical_pallet_capacity = excluded.typical_pallet_capacity,
    enclosed = excluded.enclosed,
    open_deck = excluded.open_deck,
    side_loading = excluded.side_loading,
    rear_loading = excluded.rear_loading,
    refrigerated = excluded.refrigerated,
    specialist_abnormal = excluded.specialist_abnormal,
    fuel_consumption_l_per_100km = excluded.fuel_consumption_l_per_100km,
    average_tyre_cost_per_km = excluded.average_tyre_cost_per_km,
    maintenance_cost_per_km = excluded.maintenance_cost_per_km,
    insurance_cost_per_km = excluded.insurance_cost_per_km,
    depreciation_cost_per_km = excluded.depreciation_cost_per_km,
    vehicle_overhead_per_km = excluded.vehicle_overhead_per_km,
    equipment_source_default = excluded.equipment_source_default,
    recommendation_priority = excluded.recommendation_priority,
    notes = excluded.notes,
    source_note = excluded.source_note,
    is_active = true;

create or replace function public.ttaq_sync_equipment_operating_costs()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_id uuid;
begin
  profile_id := public.ttaq_active_pricing_profile();
  if profile_id is null then
    return;
  end if;

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
  select
    profile_id,
    display_name,
    trailer_body,
    fuel_consumption_l_per_100km,
    average_tyre_cost_per_km,
    maintenance_cost_per_km,
    insurance_cost_per_km,
    depreciation_cost_per_km,
    vehicle_overhead_per_km
  from public.standard_equipment_profiles
  where is_active
  on conflict (pricing_profile_id, vehicle_type, trailer_type) do update
  set fuel_consumption_l_per_100km = excluded.fuel_consumption_l_per_100km,
      average_tyre_cost_per_km = excluded.average_tyre_cost_per_km,
      maintenance_cost_per_km = excluded.maintenance_cost_per_km,
      insurance_cost_per_km = excluded.insurance_cost_per_km,
      depreciation_cost_per_km = excluded.depreciation_cost_per_km,
      vehicle_overhead_per_km = excluded.vehicle_overhead_per_km;
end;
$$;

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
  recommendation public.vehicle_recommendations%rowtype;
  route_record public.route_estimates%rowtype;
  selected_equipment public.standard_equipment_profiles%rowtype;
  vehicle_cost public.vehicle_operating_costs%rowtype;
  driver_cost public.driver_costs%rowtype;
  overhead public.company_overheads%rowtype;
  margin_profile public.company_margin_profiles%rowtype;
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
  route_risk_amount numeric := 0;
  seasonal_amount numeric := 0;
  base_cost_value numeric := 0;
  subtotal_value numeric := 0;
  profit_value numeric := 0;
  vat_value numeric := 0;
  grand_total_value numeric := 0;
  calculation_id uuid;
  currency_value text := 'ZAR';
  rule_version_value text := 'pricing-v2-equipment';
  route_text text := '';
  route_review_required boolean := false;
begin
  profile_id := public.ttaq_active_pricing_profile();
  if profile_id is null then
    raise exception 'No active pricing profile configured';
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
    estimated_distance_km := coalesce(nullif(estimated_distance_km, 0), route_record.total_distance_km, 0);
    estimated_duration_hours := coalesce(nullif(estimated_duration_hours, 0), route_record.total_duration_hours, 0);
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

  select season_key, multiplier
    into seasonal_key, seasonal_multiplier_value
  from public.ttaq_active_seasonal_multiplier(profile_id);

  seasonal_key := coalesce(seasonal_key, 'normal');
  seasonal_multiplier_value := coalesce(seasonal_multiplier_value, public.ttaq_pricing_setting(profile_id, 'seasonal_normal_multiplier'), 1);
  fuel_price := public.ttaq_current_diesel_price(profile_id);
  diesel_base_price := nullif(public.ttaq_pricing_setting(profile_id, 'diesel_base_price_per_litre'), 0);
  fuel_surcharge_enabled := public.ttaq_pricing_setting(profile_id, 'fuel_surcharge_enabled') <> 0;
  unit_count := greatest(1, coalesce(recommendation.number_of_trucks, 1));
  overnight_count := floor(coalesce(estimated_duration_hours, 0) / 24);

  fuel_amount := round(coalesce(estimated_distance_km, 0) * unit_count * (coalesce(selected_equipment.fuel_consumption_l_per_100km, vehicle_cost.fuel_consumption_l_per_100km, 0) / 100) * coalesce(fuel_price, 0), 2);
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

  select coalesce(sum(
    fixed_amount + (amount_per_km * coalesce(estimated_distance_km, 0))
  ), public.ttaq_pricing_setting(profile_id, 'default_toll_cost'), 0)
    into toll_amount
  from public.toll_cost_rules
  where pricing_profile_id = profile_id
    and is_active
    and (route_keyword is null or route_text like '%' || lower(route_keyword) || '%')
    and (origin_keyword is null or lower(coalesce(route_record.origin_address, '')) like '%' || lower(origin_keyword) || '%')
    and (destination_keyword is null or lower(coalesce(route_record.destination_address, '')) like '%' || lower(destination_keyword) || '%');

  base_cost_value := fuel_amount + fuel_surcharge_amount + tyres_amount + maintenance_amount + insurance_amount + depreciation_amount + driver_amount + overnight_amount + vehicle_overhead_amount + escort_amount + permit_amount + hazmat_amount + refrigeration_amount + crane_amount + forklift_amount + high_value_amount + toll_amount;

  select coalesce(sum(fixed_surcharge + (base_cost_value * (surcharge_percent / 100))), public.ttaq_pricing_setting(profile_id, 'default_route_risk_surcharge'), 0),
         bool_or(manager_review_required)
    into route_risk_amount, route_review_required
  from public.route_risk_pricing_rules
  where pricing_profile_id = profile_id
    and is_active
    and (min_distance_km is null or coalesce(estimated_distance_km, 0) >= min_distance_km)
    and (route_keyword is null or route_text like '%' || lower(route_keyword) || '%')
    and (origin_keyword is null or lower(coalesce(route_record.origin_address, '')) like '%' || lower(origin_keyword) || '%')
    and (destination_keyword is null or lower(coalesce(route_record.destination_address, '')) like '%' || lower(destination_keyword) || '%');

  base_cost_value := base_cost_value + coalesce(route_risk_amount, 0);
  seasonal_amount := round(base_cost_value * (coalesce(seasonal_multiplier_value, 1) - 1), 2);
  subtotal_value := base_cost_value + seasonal_amount;
  company_overhead_amount := round(subtotal_value * (coalesce(overhead.admin_overhead_percent, 0) / 100), 2);
  subtotal_value := subtotal_value + company_overhead_amount;
  profit_value := greatest(
    round(subtotal_value * (coalesce(margin_profile.margin_percent, overhead.profit_margin_percent, 0) / 100), 2),
    coalesce(margin_profile.minimum_profit, overhead.minimum_profit, 0)
  );
  vat_value := round((subtotal_value + profit_value) * (coalesce(overhead.vat_percent, 0) / 100), 2);
  grand_total_value := subtotal_value + profit_value + vat_value;

  select currency, rule_version into currency_value, rule_version_value
  from public.pricing_profiles
  where id = profile_id;

  insert into public.pricing_calculations (
    quote_request_id, vehicle_recommendation_id, pricing_profile_id, rule_version,
    estimated_distance_km, estimated_duration_hours, total_weight_kg, total_volume_m3,
    subtotal, profit_amount, vat_amount, grand_total, recommended_selling_price,
    currency, calculation_notes, fuel_price_per_litre, fuel_surcharge_amount,
    seasonal_multiplier, seasonal_amount, toll_amount, route_risk_amount,
    margin_profile_key, margin_percent, dynamic_inputs, dynamic_outputs, manager_review_required
  )
  values (
    target_quote_request_id, recommendation.id, profile_id, coalesce(rule_version_value, 'pricing-v2-equipment'),
    coalesce(estimated_distance_km, 0), coalesce(estimated_duration_hours, 0), total_weight, total_volume,
    subtotal_value, profit_value, vat_value, grand_total_value, grand_total_value,
    coalesce(currency_value, 'ZAR'),
    'Dynamic pricing generated from route, diesel, selected equipment economics, unit count, seasonal, route risk, margin, and VAT rules.',
    fuel_price, fuel_surcharge_amount, seasonal_multiplier_value, seasonal_amount, toll_amount, route_risk_amount,
    margin_profile.margin_key, coalesce(margin_profile.margin_percent, overhead.profit_margin_percent, 0),
    jsonb_build_object(
      'selected_equipment_profile_id', selected_equipment.id,
      'selected_equipment', coalesce(selected_equipment.display_name, recommendation.override_vehicle_type, recommendation.recommended_vehicle_type),
      'equipment_source', recommendation.equipment_source,
      'unit_count', unit_count,
      'diesel_price_per_litre', fuel_price,
      'diesel_base_price_per_litre', diesel_base_price,
      'fuel_surcharge_percent', fuel_surcharge_percent,
      'seasonal_key', seasonal_key,
      'seasonal_multiplier', seasonal_multiplier_value,
      'margin_profile', margin_profile.margin_key,
      'route_provider', route_record.provider_name
    ),
    jsonb_build_object(
      'vehicle_dependent_costs_multiplier', unit_count,
      'fuel_amount', fuel_amount,
      'tyres_amount', tyres_amount,
      'maintenance_amount', maintenance_amount,
      'vehicle_insurance_amount', insurance_amount,
      'depreciation_amount', depreciation_amount,
      'driver_amount', driver_amount + overnight_amount,
      'vehicle_overhead_amount', vehicle_overhead_amount,
      'shipment_level_surcharges', escort_amount + permit_amount + hazmat_amount + refrigeration_amount + crane_amount + forklift_amount + high_value_amount,
      'base_cost_before_seasonal', base_cost_value,
      'fuel_surcharge_amount', fuel_surcharge_amount,
      'toll_amount', toll_amount,
      'route_risk_amount', route_risk_amount,
      'seasonal_amount', seasonal_amount,
      'company_overhead_amount', company_overhead_amount,
      'profit_amount', profit_value,
      'vat_amount', vat_value,
      'grand_total', grand_total_value
    ),
    coalesce(route_review_required, false) or coalesce(recommendation.manager_review_required, false)
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
    (calculation_id, target_quote_request_id, 'tolls', 'Tolls', coalesce(estimated_distance_km, 0), toll_amount, toll_amount, 'Shipment-level configurable toll framework rules matched against the route'),
    (calculation_id, target_quote_request_id, 'route_risk', 'Route risk', base_cost_value, 0, route_risk_amount, 'Shipment-level configurable route risk rules matched against distance and route text'),
    (calculation_id, target_quote_request_id, 'seasonal_multiplier', 'Seasonal multiplier', base_cost_value, seasonal_multiplier_value, seasonal_amount, 'Seasonal multiplier applied from active pricing profile'),
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
    'equipment_price_generated',
    jsonb_build_object(
      'rule_version', coalesce(rule_version_value, 'pricing-v2-equipment'),
      'recommended_selling_price', grand_total_value,
      'selected_equipment', coalesce(selected_equipment.display_name, recommendation.override_vehicle_type, recommendation.recommended_vehicle_type),
      'unit_count', unit_count,
      'fuel_price_per_litre', fuel_price,
      'seasonal_multiplier', seasonal_multiplier_value,
      'margin_profile', margin_profile.margin_key,
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

create or replace function public.ttaq_apply_equipment_override(
  target_quote_request_id uuid,
  target_equipment_profile_id uuid,
  unit_count_value integer,
  equipment_source_value text,
  override_reason_value text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  recommendation_record public.vehicle_recommendations%rowtype;
  profile_record public.standard_equipment_profiles%rowtype;
  calculation_id uuid;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Not allowed to override equipment';
  end if;

  select * into recommendation_record
  from public.vehicle_recommendations
  where quote_request_id = target_quote_request_id
  order by created_at desc
  limit 1;

  if recommendation_record.id is null then
    perform public.ttaq_generate_vehicle_recommendation(target_quote_request_id);
    select * into recommendation_record
    from public.vehicle_recommendations
    where quote_request_id = target_quote_request_id
    order by created_at desc
    limit 1;
  end if;

  if target_equipment_profile_id is null then
    update public.vehicle_recommendations
       set final_equipment_profile_id = system_equipment_profile_id,
           override_vehicle_type = null,
           override_trailer_type = null,
           override_reason = null,
           overridden_by = auth.uid(),
           overridden_at = now(),
           reset_to_system_at = now(),
           number_of_trucks = greatest(1, coalesce(unit_count_value, number_of_trucks, 1)),
           equipment_source = 'either'
     where id = recommendation_record.id;
  else
    if nullif(override_reason_value, '') is null then
      raise exception 'Override reason is required';
    end if;

    select * into profile_record
    from public.standard_equipment_profiles
    where id = target_equipment_profile_id
      and is_active;

    if profile_record.id is null then
      raise exception 'Selected equipment profile is not active';
    end if;

    update public.vehicle_recommendations
       set final_equipment_profile_id = profile_record.id,
           override_vehicle_type = profile_record.display_name,
           override_trailer_type = profile_record.trailer_body,
           override_reason = override_reason_value,
           overridden_by = auth.uid(),
           overridden_at = now(),
           number_of_trucks = greatest(1, coalesce(unit_count_value, number_of_trucks, 1)),
           equipment_source = case
             when equipment_source_value in ('own_fleet', 'subcontractor', 'either') then equipment_source_value
             else 'either'
           end
     where id = recommendation_record.id;
  end if;

  calculation_id := public.ttaq_generate_price(target_quote_request_id, 0, 0);
  return calculation_id;
end;
$$;

select public.ttaq_sync_equipment_operating_costs();

create or replace function public.ttaq_generate_vehicle_recommendation(target_quote_request_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  total_weight numeric := 0;
  total_volume numeric := 0;
  total_deck_area numeric := 0;
  max_length numeric := 0;
  max_width numeric := 0;
  max_height numeric := 0;
  max_item_weight numeric := 0;
  item_count numeric := 0;
  total_value numeric := 0;
  has_dangerous boolean := false;
  has_temperature boolean := false;
  has_fragile boolean := false;
  has_machinery boolean := false;
  has_pallets boolean := false;
  has_crane_answer boolean := false;
  has_forklift_text boolean := false;
  missing_dimensions_value boolean := false;
  dimensionally_abnormal_value boolean := false;
  payload_capacity_review_value boolean := false;
  deck_capacity_review_value boolean := false;
  volume_capacity_review_value boolean := false;
  abnormal_load_value boolean := false;
  permit_required_value boolean := false;
  escort_recommended_value boolean := false;
  crane_required_value boolean := false;
  forklift_required_value boolean := false;
  manager_review_value boolean := false;
  selected_profile public.standard_equipment_profiles%rowtype;
  alternatives jsonb := '[]'::jsonb;
  trucks integer := 1;
  payload_util numeric := 0;
  volume_util numeric := 0;
  deck_util numeric := 0;
  notes text;
  reasoning jsonb;
  recommendation_id uuid;
begin
  select
    coalesce(sum(coalesce(
      nullif(substring(coalesce(qi.notes, '') from 'Total shipment weight:\s*([0-9]+(?:\.[0-9]+)?)\s*kg'), '')::numeric,
      coalesce(qi.quantity, 1) * coalesce(qi.weight_kg, 0)
    )), 0),
    coalesce(sum(coalesce(qi.quantity, 1) * coalesce(qi.length_m, 0) * coalesce(qi.width_m, 0) * coalesce(qi.height_m, 0)), 0),
    coalesce(sum(coalesce(qi.quantity, 1) * coalesce(qi.length_m, 0) * coalesce(qi.width_m, 0)), 0),
    coalesce(max(coalesce(qi.length_m, 0)), 0),
    coalesce(max(coalesce(qi.width_m, 0)), 0),
    coalesce(max(coalesce(qi.height_m, 0)), 0),
    coalesce(max(coalesce(qi.weight_kg, 0)), 0),
    coalesce(sum(coalesce(qi.quantity, 1)), 0),
    coalesce(sum(coalesce(qi.cargo_value, 0)), 0),
    coalesce(bool_or(coalesce(qi.dangerous_goods, false) or qi.cargo_category::text = 'dangerous_goods'), false),
    coalesce(bool_or(coalesce(qi.temperature_controlled, false) or qi.cargo_category::text = 'refrigerated'), false),
    coalesce(bool_or(coalesce(qi.fragile, false)), false),
    coalesce(bool_or(qi.cargo_category::text = 'machinery'), false),
    coalesce(bool_or(coalesce(qi.notes, '') ilike '%Freight type: Pallets%'), false),
    coalesce(bool_or(
      (qi.cargo_category::text = 'machinery' or coalesce(qi.notes, '') ilike '%Freight type: Pallets%')
      and (coalesce(qi.length_m, 0) <= 0 or coalesce(qi.width_m, 0) <= 0 or coalesce(qi.height_m, 0) <= 0)
    ), false)
  into
    total_weight, total_volume, total_deck_area, max_length, max_width, max_height, max_item_weight,
    item_count, total_value, has_dangerous, has_temperature, has_fragile, has_machinery, has_pallets, missing_dimensions_value
  from public.quote_items qi
  where qi.quote_request_id = target_quote_request_id;

  select coalesce(bool_or(lower(coalesce(answer_value, '')) in ('yes', 'true', 'required')), false)
    into has_crane_answer
  from public.rfq_dynamic_answers
  where quote_request_id = target_quote_request_id
    and question_key in ('crane_required', 'crane', 'lifting_required');

  select coalesce(bool_or(
      lower(coalesce(loading_method, '')) like '%forklift%'
      or lower(coalesce(offloading_method, '')) like '%forklift%'
    ), false)
    into has_forklift_text
  from public.quote_stops
  where quote_request_id = target_quote_request_id;

  dimensionally_abnormal_value := max_length > 12 or max_width > 2.5 or max_height > 4.3;
  abnormal_load_value := dimensionally_abnormal_value;
  permit_required_value := dimensionally_abnormal_value;
  escort_recommended_value := max_width > 3.5 or max_length > 22;
  crane_required_value := has_crane_answer or (has_machinery and total_weight > 8000);
  forklift_required_value := has_forklift_text or (not has_machinery and total_weight > 1000);

  with candidate_scores as (
    select
      ep.*,
      greatest(
        1,
        ceiling(greatest(
          case when coalesce(ep.payload_capacity_kg, 0) > 0 then total_weight / ep.payload_capacity_kg else 1 end,
          case when coalesce(ep.usable_cube_m3, 0) > 0 then total_volume / ep.usable_cube_m3 else 1 end,
          case when coalesce(ep.usable_deck_area_m2, 0) > 0 then total_deck_area / ep.usable_deck_area_m2 else 1 end,
          case when coalesce(ep.typical_pallet_capacity, 0) > 0 and has_pallets then item_count / ep.typical_pallet_capacity else 1 end
        ))::integer
      ) as required_units
    from public.standard_equipment_profiles ep
    where ep.is_active
      and (not has_temperature or ep.refrigerated)
      and (not dimensionally_abnormal_value or ep.specialist_abnormal)
      and (dimensionally_abnormal_value or not ep.specialist_abnormal)
      and (not crane_required_value or ep.open_deck or ep.specialist_abnormal)
      and (not has_machinery or ep.open_deck or ep.specialist_abnormal)
      and (max_length = 0 or ep.deck_length_m is null or max_length <= ep.deck_length_m)
      and (max_width = 0 or ep.deck_width_m is null or max_width <= ep.deck_width_m)
      and (max_item_weight = 0 or ep.payload_capacity_kg is null or max_item_weight <= ep.payload_capacity_kg)
  )
  select * into selected_profile
  from candidate_scores
  order by
    required_units,
    case when has_pallets and enclosed then 0 when has_pallets then 1 else 0 end,
    case when has_machinery and open_deck then 0 when has_machinery then 1 else 0 end,
    recommendation_priority,
    coalesce(payload_capacity_kg, 999999),
    coalesce(usable_cube_m3, 999999)
  limit 1;

  if selected_profile.id is null then
    select * into selected_profile
    from public.standard_equipment_profiles
    where is_active and specialist_abnormal
    order by recommendation_priority
    limit 1;
    manager_review_value := true;
  end if;

  trucks := greatest(
    1,
    ceiling(greatest(
      case when coalesce(selected_profile.payload_capacity_kg, 0) > 0 then total_weight / selected_profile.payload_capacity_kg else 1 end,
      case when coalesce(selected_profile.usable_cube_m3, 0) > 0 then total_volume / selected_profile.usable_cube_m3 else 1 end,
      case when coalesce(selected_profile.usable_deck_area_m2, 0) > 0 then total_deck_area / selected_profile.usable_deck_area_m2 else 1 end,
      case when coalesce(selected_profile.typical_pallet_capacity, 0) > 0 and has_pallets then item_count / selected_profile.typical_pallet_capacity else 1 end
    ))::integer
  );

  payload_util := least(100, round((total_weight / nullif(coalesce(selected_profile.payload_capacity_kg, 0) * trucks, 0)) * 100, 2));
  volume_util := least(100, round((total_volume / nullif(coalesce(selected_profile.usable_cube_m3, 0) * trucks, 0)) * 100, 2));
  deck_util := least(100, round((total_deck_area / nullif(coalesce(selected_profile.usable_deck_area_m2, 0) * trucks, 0)) * 100, 2));
  payload_capacity_review_value := coalesce(selected_profile.payload_capacity_kg, 0) > 0 and total_weight > selected_profile.payload_capacity_kg * trucks;
  deck_capacity_review_value := coalesce(selected_profile.usable_deck_area_m2, 0) > 0 and total_deck_area > selected_profile.usable_deck_area_m2 * trucks;
  volume_capacity_review_value := coalesce(selected_profile.usable_cube_m3, 0) > 0 and total_volume > selected_profile.usable_cube_m3 * trucks;

  manager_review_value := coalesce(manager_review_value, false)
    or missing_dimensions_value
    or dimensionally_abnormal_value
    or payload_capacity_review_value
    or deck_capacity_review_value
    or volume_capacity_review_value
    or has_dangerous
    or has_temperature
    or crane_required_value
    or total_value >= 500000
    or has_fragile;

  with alternatives_ranked as (
    select
      ep.id,
      ep.equipment_code,
      ep.display_name,
      ep.trailer_body,
      greatest(
        1,
        ceiling(greatest(
          case when coalesce(ep.payload_capacity_kg, 0) > 0 then total_weight / ep.payload_capacity_kg else 1 end,
          case when coalesce(ep.usable_cube_m3, 0) > 0 then total_volume / ep.usable_cube_m3 else 1 end,
          case when coalesce(ep.usable_deck_area_m2, 0) > 0 then total_deck_area / ep.usable_deck_area_m2 else 1 end,
          case when coalesce(ep.typical_pallet_capacity, 0) > 0 and has_pallets then item_count / ep.typical_pallet_capacity else 1 end
        ))::integer
      ) as units
    from public.standard_equipment_profiles ep
    where ep.is_active
      and ep.id <> selected_profile.id
      and (not has_temperature or ep.refrigerated)
      and (not dimensionally_abnormal_value or ep.specialist_abnormal)
      and (dimensionally_abnormal_value or not ep.specialist_abnormal)
      and (not crane_required_value or ep.open_deck or ep.specialist_abnormal)
      and (not has_machinery or ep.open_deck or ep.specialist_abnormal)
      and (max_length = 0 or ep.deck_length_m is null or max_length <= ep.deck_length_m)
      and (max_width = 0 or ep.deck_width_m is null or max_width <= ep.deck_width_m)
      and (max_item_weight = 0 or ep.payload_capacity_kg is null or max_item_weight <= ep.payload_capacity_kg)
    order by units, ep.recommendation_priority
    limit 2
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id,
    'equipment_code', equipment_code,
    'display_name', display_name,
    'trailer_body', trailer_body,
    'units', units
  )), '[]'::jsonb)
  into alternatives
  from alternatives_ranked;

  reasoning := jsonb_build_array(
    item_count || ' item(s) evaluated.',
    'Total shipment weight ' || total_weight || ' kg.',
    'Deck footprint ' || round(total_deck_area, 2) || ' m2.',
    'Cube ' || round(total_volume, 2) || ' m3.',
    case when has_pallets then 'Palletised freight: enclosed tautliner/curtainsider profiles are preferred.' else 'Freight type does not force a palletised body.' end,
    case when has_machinery or crane_required_value then 'Open deck/flatdeck suitability considered for machinery or crane loading.' else 'No machinery/open-deck requirement detected.' end,
    case when has_temperature then 'Temperature control requires reefer-capable equipment.' else 'No temperature-control requirement detected.' end,
    case when dimensionally_abnormal_value then 'Dimensions exceed the current configured normal envelope; abnormal review required.' else 'No abnormal dimensions detected by the current configured rule.' end,
    trucks || ' unit(s) required based on configured payload, cube, deck, and pallet capacity where available.'
  );

  notes := concat_ws(
    ' ',
    'Recommended Equipment:',
    selected_profile.display_name || '.',
    'Units: ' || trucks || '.',
    'Why:',
    array_to_string(array(select jsonb_array_elements_text(reasoning)), ' ')
  );

  delete from public.transport_requirement_flags where quote_request_id = target_quote_request_id;
  delete from public.vehicle_recommendations where quote_request_id = target_quote_request_id;

  insert into public.vehicle_recommendations (
    quote_request_id,
    recommended_vehicle_type,
    recommended_trailer_type,
    number_of_trucks,
    estimated_payload_utilization_percent,
    estimated_volume_utilization_percent,
    abnormal_load,
    permit_required,
    escort_recommended,
    hazmat_required,
    refrigeration_required,
    crane_required,
    forklift_required,
    manager_review_required,
    recommendation_notes,
    system_equipment_profile_id,
    final_equipment_profile_id,
    equipment_source,
    equipment_alternatives,
    estimated_deck_utilization_percent,
    recommendation_reasoning
  )
  values (
    target_quote_request_id,
    selected_profile.display_name,
    selected_profile.trailer_body,
    trucks,
    coalesce(payload_util, 0),
    coalesce(volume_util, 0),
    abnormal_load_value,
    permit_required_value,
    escort_recommended_value,
    has_dangerous,
    has_temperature,
    crane_required_value,
    forklift_required_value,
    manager_review_value,
    notes,
    selected_profile.id,
    selected_profile.id,
    coalesce(selected_profile.equipment_source_default, 'either'),
    alternatives,
    coalesce(deck_util, 0),
    reasoning
  )
  returning id into recommendation_id;

  insert into public.transport_requirement_flags (quote_request_id, vehicle_recommendation_id, flag_key, flag_label, severity, flag_notes)
  select target_quote_request_id, recommendation_id, flag_key, flag_label, severity, flag_notes
  from (
    values
      ('dimensions_required', 'Dimensions required', 'warning', 'Palletised or machinery freight requires length, width, and height before relying on the recommendation.', missing_dimensions_value),
      ('payload_capacity_review', 'Payload capacity review', 'warning', 'Payload exceeds the selected configured profile capacity after unit calculation; manager review required.', payload_capacity_review_value),
      ('deck_capacity_review', 'Deck capacity review', 'warning', 'Deck footprint exceeds the selected configured profile after unit calculation; manager review required.', deck_capacity_review_value),
      ('volume_capacity_review', 'Volume capacity review', 'warning', 'Cube exceeds the selected configured profile after unit calculation; manager review required.', volume_capacity_review_value),
      ('abnormal_load', 'Abnormal load', 'warning', 'Dimensions may exceed normal transport limits.', abnormal_load_value),
      ('permit_required', 'Permit required', 'warning', 'Permit review is recommended for abnormal dimensions.', permit_required_value),
      ('escort_recommended', 'Escort recommended', 'warning', 'Escort vehicle may be required for abnormal dimensions.', escort_recommended_value),
      ('hazmat_required', 'Hazmat required', 'critical', 'Dangerous goods handling and documentation required.', has_dangerous),
      ('refrigeration_required', 'Refrigeration required', 'warning', 'Temperature-controlled equipment required.', has_temperature),
      ('crane_required', 'Crane required', 'warning', 'Crane loading/offloading or lifting review required.', crane_required_value),
      ('forklift_required', 'Forklift required', 'info', 'Forklift loading/offloading likely required.', forklift_required_value),
      ('manager_review_required', 'Manager review required', 'critical', 'Manager review required before final quote.', manager_review_value)
  ) as flags(flag_key, flag_label, severity, flag_notes, is_active)
  where is_active;

  update public.quote_requests
     set suggestion_notes = notes
   where id = target_quote_request_id;

  return recommendation_id;
end;
$$;
