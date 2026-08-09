do $$
declare
  profile_id uuid;
begin
  update public.pricing_profiles
     set is_active = false
   where name <> 'Time Trucking Default 2026';

  insert into public.pricing_profiles (
    name,
    is_active,
    currency,
    quote_validity_days,
    rule_version
  )
  values (
    'Time Trucking Default 2026',
    true,
    'ZAR',
    7,
    'pricing-default-2026'
  )
  on conflict (name) do update
  set is_active = true,
      currency = excluded.currency,
      quote_validity_days = excluded.quote_validity_days,
      rule_version = excluded.rule_version
  returning id into profile_id;

  delete from public.fuel_price_history
   where pricing_profile_id = profile_id
     and effective_from = date '2026-01-01';

  insert into public.fuel_price_history (
    pricing_profile_id,
    fuel_price_per_litre,
    effective_from
  )
  values (
    profile_id,
    24,
    date '2026-01-01'
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
  values
    (profile_id, 'default', 'default', 35, 1.80, 3.50, 1.20, 2.50, 0),
    (profile_id, '8 ton', 'Curtain side', 35, 1.80, 3.50, 1.20, 2.50, 0),
    (profile_id, '14 ton', 'Tautliner / curtain side', 38, 2.10, 4.20, 1.50, 3.00, 0),
    (profile_id, 'Rigid truck / horse', 'Flatdeck / tri-axle', 42, 2.60, 5.00, 1.80, 3.80, 0),
    (profile_id, 'Heavy haulage truck', 'Lowbed', 55, 3.50, 7.00, 2.60, 5.50, 0),
    (profile_id, 'Hazmat-capable vehicle', 'Hazmat-compatible trailer', 42, 2.80, 5.50, 2.20, 4.00, 0),
    (profile_id, 'Refrigerated vehicle', 'Refrigerated trailer', 45, 2.80, 5.70, 2.20, 4.20, 0)
  on conflict (pricing_profile_id, vehicle_type, trailer_type) do update
  set fuel_consumption_l_per_100km = excluded.fuel_consumption_l_per_100km,
      average_tyre_cost_per_km = excluded.average_tyre_cost_per_km,
      maintenance_cost_per_km = excluded.maintenance_cost_per_km,
      insurance_cost_per_km = excluded.insurance_cost_per_km,
      depreciation_cost_per_km = excluded.depreciation_cost_per_km,
      vehicle_overhead_per_km = excluded.vehicle_overhead_per_km;

  delete from public.driver_costs
   where pricing_profile_id = profile_id;

  insert into public.driver_costs (
    pricing_profile_id,
    driver_hourly_wage,
    driver_overnight_allowance
  )
  values (
    profile_id,
    120,
    650
  );

  delete from public.company_overheads
   where pricing_profile_id = profile_id;

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
    10,
    20,
    15,
    1500,
    10
  );

  insert into public.pricing_settings (
    pricing_profile_id,
    setting_key,
    setting_value,
    setting_unit,
    description
  )
  values
    (profile_id, 'escort_surcharge', 3500, 'ZAR', 'Starter escort surcharge'),
    (profile_id, 'permit_surcharge', 2500, 'ZAR', 'Starter permit surcharge'),
    (profile_id, 'hazmat_surcharge', 1800, 'ZAR', 'Starter dangerous goods surcharge'),
    (profile_id, 'refrigeration_surcharge', 2200, 'ZAR', 'Starter refrigeration surcharge'),
    (profile_id, 'crane_surcharge', 3000, 'ZAR', 'Starter crane surcharge'),
    (profile_id, 'forklift_surcharge', 800, 'ZAR', 'Starter forklift surcharge'),
    (profile_id, 'high_value_threshold', 500000, 'ZAR', 'Starter high-value cargo threshold'),
    (profile_id, 'high_value_surcharge', 1500, 'ZAR', 'Starter high-value cargo surcharge')
  on conflict (pricing_profile_id, setting_key) do update
  set setting_value = excluded.setting_value,
      setting_unit = excluded.setting_unit,
      description = excluded.description;
end;
$$;

