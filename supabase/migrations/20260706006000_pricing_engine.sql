create extension if not exists pgcrypto;

create table if not exists public.pricing_profiles (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  is_active boolean not null default false,
  currency text not null default 'ZAR',
  quote_validity_days integer,
  rule_version text not null default 'pricing-v1',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.fuel_price_history (
  id uuid primary key default gen_random_uuid(),
  pricing_profile_id uuid references public.pricing_profiles(id) on delete cascade,
  fuel_price_per_litre numeric(14, 4) not null default 0,
  effective_from date not null default current_date,
  created_at timestamptz not null default now()
);

create table if not exists public.vehicle_operating_costs (
  id uuid primary key default gen_random_uuid(),
  pricing_profile_id uuid references public.pricing_profiles(id) on delete cascade,
  vehicle_type text not null,
  trailer_type text,
  fuel_consumption_l_per_100km numeric(14, 4) not null default 0,
  average_tyre_cost_per_km numeric(14, 4) not null default 0,
  maintenance_cost_per_km numeric(14, 4) not null default 0,
  insurance_cost_per_km numeric(14, 4) not null default 0,
  depreciation_cost_per_km numeric(14, 4) not null default 0,
  vehicle_overhead_per_km numeric(14, 4) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (pricing_profile_id, vehicle_type, trailer_type)
);

create table if not exists public.driver_costs (
  id uuid primary key default gen_random_uuid(),
  pricing_profile_id uuid references public.pricing_profiles(id) on delete cascade,
  driver_hourly_wage numeric(14, 4) not null default 0,
  driver_overnight_allowance numeric(14, 2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.company_overheads (
  id uuid primary key default gen_random_uuid(),
  pricing_profile_id uuid references public.pricing_profiles(id) on delete cascade,
  admin_overhead_percent numeric(7, 4) not null default 0,
  profit_margin_percent numeric(7, 4) not null default 0,
  vat_percent numeric(7, 4) not null default 0,
  minimum_profit numeric(14, 2) not null default 0,
  maximum_discount_percent numeric(7, 4) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.pricing_settings (
  id uuid primary key default gen_random_uuid(),
  pricing_profile_id uuid references public.pricing_profiles(id) on delete cascade,
  setting_key text not null,
  setting_value numeric(14, 4) not null default 0,
  setting_unit text,
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (pricing_profile_id, setting_key)
);

create table if not exists public.pricing_calculations (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  vehicle_recommendation_id uuid references public.vehicle_recommendations(id) on delete set null,
  pricing_profile_id uuid references public.pricing_profiles(id) on delete set null,
  calculation_timestamp timestamptz not null default now(),
  rule_version text not null,
  estimated_distance_km numeric(14, 2) not null default 0,
  estimated_duration_hours numeric(14, 2) not null default 0,
  total_weight_kg numeric(14, 2) not null default 0,
  total_volume_m3 numeric(14, 3) not null default 0,
  subtotal numeric(14, 2) not null default 0,
  profit_amount numeric(14, 2) not null default 0,
  vat_amount numeric(14, 2) not null default 0,
  grand_total numeric(14, 2) not null default 0,
  recommended_selling_price numeric(14, 2) not null default 0,
  currency text not null default 'ZAR',
  approved_by uuid references public.internal_users(id),
  approved_at timestamptz,
  calculation_notes text,
  created_at timestamptz not null default now()
);

create table if not exists public.pricing_breakdowns (
  id uuid primary key default gen_random_uuid(),
  pricing_calculation_id uuid not null references public.pricing_calculations(id) on delete cascade,
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  line_key text not null,
  line_label text not null,
  quantity numeric(14, 4) not null default 0,
  unit_rate numeric(14, 4) not null default 0,
  amount numeric(14, 2) not null default 0,
  explanation text,
  created_at timestamptz not null default now()
);

create table if not exists public.pricing_adjustments (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  pricing_calculation_id uuid references public.pricing_calculations(id) on delete set null,
  adjusted_selling_price numeric(14, 2) not null,
  previous_selling_price numeric(14, 2),
  adjustment_reason text not null,
  adjusted_by uuid references public.internal_users(id),
  created_at timestamptz not null default now()
);

create trigger ttaq_pricing_profiles_touch_updated_at
before update on public.pricing_profiles
for each row execute function public.ttaq_touch_updated_at();

create trigger ttaq_vehicle_operating_costs_touch_updated_at
before update on public.vehicle_operating_costs
for each row execute function public.ttaq_touch_updated_at();

create trigger ttaq_driver_costs_touch_updated_at
before update on public.driver_costs
for each row execute function public.ttaq_touch_updated_at();

create trigger ttaq_company_overheads_touch_updated_at
before update on public.company_overheads
for each row execute function public.ttaq_touch_updated_at();

create trigger ttaq_pricing_settings_touch_updated_at
before update on public.pricing_settings
for each row execute function public.ttaq_touch_updated_at();

alter table public.pricing_profiles enable row level security;
alter table public.fuel_price_history enable row level security;
alter table public.vehicle_operating_costs enable row level security;
alter table public.driver_costs enable row level security;
alter table public.company_overheads enable row level security;
alter table public.pricing_settings enable row level security;
alter table public.pricing_calculations enable row level security;
alter table public.pricing_breakdowns enable row level security;
alter table public.pricing_adjustments enable row level security;

create policy "Internal users read pricing profiles" on public.pricing_profiles for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
create policy "Owner manages pricing profiles" on public.pricing_profiles for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

create policy "Internal users read fuel history" on public.fuel_price_history for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
create policy "Owner manages fuel history" on public.fuel_price_history for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

create policy "Internal users read vehicle costs" on public.vehicle_operating_costs for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
create policy "Owner manages vehicle costs" on public.vehicle_operating_costs for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

create policy "Internal users read driver costs" on public.driver_costs for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
create policy "Owner manages driver costs" on public.driver_costs for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

create policy "Internal users read company overheads" on public.company_overheads for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
create policy "Owner manages company overheads" on public.company_overheads for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

create policy "Internal users read pricing settings" on public.pricing_settings for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
create policy "Owner manages pricing settings" on public.pricing_settings for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

create policy "Internal users read pricing calculations" on public.pricing_calculations for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
create policy "Owner and manager manage pricing calculations" on public.pricing_calculations for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read pricing breakdowns" on public.pricing_breakdowns for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
create policy "Owner and manager manage pricing breakdowns" on public.pricing_breakdowns for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read pricing adjustments" on public.pricing_adjustments for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
create policy "Owner and manager manage pricing adjustments" on public.pricing_adjustments for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create index if not exists ttaq_pricing_calculations_quote_request_id_idx on public.pricing_calculations(quote_request_id);
create index if not exists ttaq_pricing_breakdowns_calculation_id_idx on public.pricing_breakdowns(pricing_calculation_id);
create index if not exists ttaq_pricing_adjustments_quote_request_id_idx on public.pricing_adjustments(quote_request_id);

insert into public.pricing_profiles (name, is_active, currency, quote_validity_days, rule_version)
values ('Default configurable profile', true, 'ZAR', 7, 'pricing-v1')
on conflict (name) do update
set is_active = true,
    currency = excluded.currency,
    quote_validity_days = excluded.quote_validity_days,
    rule_version = excluded.rule_version;

insert into public.pricing_settings (pricing_profile_id, setting_key, setting_value, setting_unit, description)
select p.id, setting_key, 0, setting_unit, description
from public.pricing_profiles p
cross join (
  values
    ('escort_surcharge', 'currency', 'Configurable escort surcharge'),
    ('permit_surcharge', 'currency', 'Configurable permit surcharge'),
    ('hazmat_surcharge', 'currency', 'Configurable dangerous goods surcharge'),
    ('refrigeration_surcharge', 'currency', 'Configurable refrigeration surcharge'),
    ('crane_surcharge', 'currency', 'Configurable crane surcharge'),
    ('forklift_surcharge', 'currency', 'Configurable forklift surcharge'),
    ('high_value_threshold', 'currency', 'Cargo value threshold for high-value handling'),
    ('high_value_surcharge', 'currency', 'Configurable high-value cargo surcharge')
) as defaults(setting_key, setting_unit, description)
where p.name = 'Default configurable profile'
on conflict (pricing_profile_id, setting_key) do nothing;

create or replace function public.ttaq_active_pricing_profile()
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  select id from public.pricing_profiles where is_active order by created_at desc limit 1;
$$;

create or replace function public.ttaq_pricing_setting(profile_id uuid, key_name text)
returns numeric
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((
    select setting_value
    from public.pricing_settings
    where pricing_profile_id = profile_id
      and setting_key = key_name
    limit 1
  ), 0);
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
  vehicle_cost public.vehicle_operating_costs%rowtype;
  driver_cost public.driver_costs%rowtype;
  overhead public.company_overheads%rowtype;
  fuel_price numeric := 0;
  total_weight numeric := 0;
  total_volume numeric := 0;
  total_value numeric := 0;
  overnight_count numeric := 0;
  fuel_amount numeric := 0;
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
  subtotal_value numeric := 0;
  profit_value numeric := 0;
  vat_value numeric := 0;
  grand_total_value numeric := 0;
  calculation_id uuid;
  currency_value text := 'ZAR';
  rule_version_value text := 'pricing-v1';
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

  select coalesce(sum(coalesce(quantity, 1) * coalesce(weight_kg, 0)), 0),
         coalesce(sum(coalesce(quantity, 1) * coalesce(length_m, 0) * coalesce(width_m, 0) * coalesce(height_m, 0)), 0),
         coalesce(sum(coalesce(cargo_value, 0)), 0)
    into total_weight, total_volume, total_value
  from public.quote_items
  where quote_request_id = target_quote_request_id;

  select * into vehicle_cost
  from public.vehicle_operating_costs
  where pricing_profile_id = profile_id
    and (
      vehicle_type = recommendation.recommended_vehicle_type
      or vehicle_type = 'default'
    )
  order by case when vehicle_type = recommendation.recommended_vehicle_type then 0 else 1 end
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

  select fuel_price_per_litre into fuel_price
  from public.fuel_price_history
  where pricing_profile_id = profile_id
  order by effective_from desc, created_at desc
  limit 1;

  fuel_price := coalesce(fuel_price, 0);
  overnight_count := floor(coalesce(estimated_duration_hours, 0) / 24);

  fuel_amount := round(coalesce(estimated_distance_km, 0) * (coalesce(vehicle_cost.fuel_consumption_l_per_100km, 0) / 100) * fuel_price, 2);
  tyres_amount := round(coalesce(estimated_distance_km, 0) * coalesce(vehicle_cost.average_tyre_cost_per_km, 0), 2);
  maintenance_amount := round(coalesce(estimated_distance_km, 0) * coalesce(vehicle_cost.maintenance_cost_per_km, 0), 2);
  insurance_amount := round(coalesce(estimated_distance_km, 0) * coalesce(vehicle_cost.insurance_cost_per_km, 0), 2);
  depreciation_amount := round(coalesce(estimated_distance_km, 0) * coalesce(vehicle_cost.depreciation_cost_per_km, 0), 2);
  driver_amount := round(coalesce(estimated_duration_hours, 0) * coalesce(driver_cost.driver_hourly_wage, 0), 2);
  overnight_amount := round(overnight_count * coalesce(driver_cost.driver_overnight_allowance, 0), 2);
  vehicle_overhead_amount := round(coalesce(estimated_distance_km, 0) * coalesce(vehicle_cost.vehicle_overhead_per_km, 0), 2);

  escort_amount := case when coalesce(recommendation.escort_recommended, false) then public.ttaq_pricing_setting(profile_id, 'escort_surcharge') else 0 end;
  permit_amount := case when coalesce(recommendation.permit_required, false) then public.ttaq_pricing_setting(profile_id, 'permit_surcharge') else 0 end;
  hazmat_amount := case when coalesce(recommendation.hazmat_required, false) then public.ttaq_pricing_setting(profile_id, 'hazmat_surcharge') else 0 end;
  refrigeration_amount := case when coalesce(recommendation.refrigeration_required, false) then public.ttaq_pricing_setting(profile_id, 'refrigeration_surcharge') else 0 end;
  crane_amount := case when coalesce(recommendation.crane_required, false) then public.ttaq_pricing_setting(profile_id, 'crane_surcharge') else 0 end;
  forklift_amount := case when coalesce(recommendation.forklift_required, false) then public.ttaq_pricing_setting(profile_id, 'forklift_surcharge') else 0 end;
  high_value_amount := case when total_value >= public.ttaq_pricing_setting(profile_id, 'high_value_threshold') and public.ttaq_pricing_setting(profile_id, 'high_value_threshold') > 0 then public.ttaq_pricing_setting(profile_id, 'high_value_surcharge') else 0 end;

  subtotal_value := fuel_amount + tyres_amount + maintenance_amount + insurance_amount + depreciation_amount + driver_amount + overnight_amount + vehicle_overhead_amount + escort_amount + permit_amount + hazmat_amount + refrigeration_amount + crane_amount + forklift_amount + high_value_amount;
  company_overhead_amount := round(subtotal_value * (coalesce(overhead.admin_overhead_percent, 0) / 100), 2);
  subtotal_value := subtotal_value + company_overhead_amount;
  profit_value := greatest(round(subtotal_value * (coalesce(overhead.profit_margin_percent, 0) / 100), 2), coalesce(overhead.minimum_profit, 0));
  vat_value := round((subtotal_value + profit_value) * (coalesce(overhead.vat_percent, 0) / 100), 2);
  grand_total_value := subtotal_value + profit_value + vat_value;

  select currency, rule_version into currency_value, rule_version_value
  from public.pricing_profiles
  where id = profile_id;

  insert into public.pricing_calculations (
    quote_request_id,
    vehicle_recommendation_id,
    pricing_profile_id,
    rule_version,
    estimated_distance_km,
    estimated_duration_hours,
    total_weight_kg,
    total_volume_m3,
    subtotal,
    profit_amount,
    vat_amount,
    grand_total,
    recommended_selling_price,
    currency,
    calculation_notes
  )
  values (
    target_quote_request_id,
    recommendation.id,
    profile_id,
    coalesce(rule_version_value, 'pricing-v1'),
    coalesce(estimated_distance_km, 0),
    coalesce(estimated_duration_hours, 0),
    total_weight,
    total_volume,
    subtotal_value,
    profit_value,
    vat_value,
    grand_total_value,
    grand_total_value,
    coalesce(currency_value, 'ZAR'),
    'Pricing generated from configurable Time Trucking pricing profile.'
  )
  returning id into calculation_id;

  insert into public.pricing_breakdowns (pricing_calculation_id, quote_request_id, line_key, line_label, quantity, unit_rate, amount, explanation)
  values
    (calculation_id, target_quote_request_id, 'fuel', 'Fuel', coalesce(estimated_distance_km, 0), fuel_price, fuel_amount, 'Distance x fuel consumption x fuel price'),
    (calculation_id, target_quote_request_id, 'driver', 'Driver', coalesce(estimated_duration_hours, 0), coalesce(driver_cost.driver_hourly_wage, 0), driver_amount + overnight_amount, 'Driver wages plus overnight allowance'),
    (calculation_id, target_quote_request_id, 'maintenance', 'Maintenance', coalesce(estimated_distance_km, 0), coalesce(vehicle_cost.maintenance_cost_per_km, 0), maintenance_amount, 'Distance x maintenance cost/km'),
    (calculation_id, target_quote_request_id, 'insurance', 'Insurance', coalesce(estimated_distance_km, 0), coalesce(vehicle_cost.insurance_cost_per_km, 0), insurance_amount, 'Distance x insurance cost/km'),
    (calculation_id, target_quote_request_id, 'depreciation', 'Depreciation', coalesce(estimated_distance_km, 0), coalesce(vehicle_cost.depreciation_cost_per_km, 0), depreciation_amount, 'Distance x depreciation cost/km'),
    (calculation_id, target_quote_request_id, 'overhead', 'Overhead', subtotal_value, coalesce(overhead.admin_overhead_percent, 0), company_overhead_amount + vehicle_overhead_amount, 'Vehicle overhead plus company admin overhead'),
    (calculation_id, target_quote_request_id, 'escort', 'Escort', 1, escort_amount, escort_amount, 'Configurable escort surcharge when recommended'),
    (calculation_id, target_quote_request_id, 'permit', 'Permit', 1, permit_amount, permit_amount, 'Configurable permit surcharge when required'),
    (calculation_id, target_quote_request_id, 'hazmat', 'Hazmat', 1, hazmat_amount, hazmat_amount, 'Configurable dangerous goods surcharge'),
    (calculation_id, target_quote_request_id, 'refrigeration', 'Refrigeration', 1, refrigeration_amount, refrigeration_amount, 'Configurable refrigeration surcharge'),
    (calculation_id, target_quote_request_id, 'crane', 'Crane', 1, crane_amount, crane_amount, 'Configurable crane surcharge'),
    (calculation_id, target_quote_request_id, 'forklift', 'Forklift', 1, forklift_amount, forklift_amount, 'Configurable forklift surcharge'),
    (calculation_id, target_quote_request_id, 'profit', 'Profit', subtotal_value, coalesce(overhead.profit_margin_percent, 0), profit_value, 'Profit margin with minimum profit applied'),
    (calculation_id, target_quote_request_id, 'vat', 'VAT', subtotal_value + profit_value, coalesce(overhead.vat_percent, 0), vat_value, 'VAT applied after profit');

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
  previous_price numeric;
  adjustment_id uuid;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Not allowed to adjust pricing';
  end if;

  select recommended_selling_price into previous_price
  from public.pricing_calculations
  where id = target_pricing_calculation_id;

  insert into public.pricing_adjustments (
    quote_request_id,
    pricing_calculation_id,
    adjusted_selling_price,
    previous_selling_price,
    adjustment_reason,
    adjusted_by
  )
  values (
    target_quote_request_id,
    target_pricing_calculation_id,
    adjusted_selling_price_value,
    previous_price,
    adjustment_reason_value,
    auth.uid()
  )
  returning id into adjustment_id;

  update public.quote_requests
     set adjusted_price = adjusted_selling_price_value
   where id = target_quote_request_id;

  return adjustment_id;
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
      coalesce(settings_payload->>'rule_version', 'pricing-v1')
    )
    returning id into profile_id;
  else
    update public.pricing_profiles
       set currency = coalesce(settings_payload->>'currency', currency),
           quote_validity_days = coalesce(nullif(settings_payload->>'quote_validity_days', '')::integer, quote_validity_days),
           rule_version = coalesce(settings_payload->>'rule_version', rule_version)
     where id = profile_id;
  end if;

  insert into public.fuel_price_history (pricing_profile_id, fuel_price_per_litre, effective_from)
  values (
    profile_id,
    coalesce(nullif(settings_payload->>'fuel_price_per_litre', '')::numeric, 0),
    current_date
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
    'default',
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

  insert into public.pricing_settings (pricing_profile_id, setting_key, setting_value, setting_unit, description)
  select profile_id, key, coalesce(nullif(value, '')::numeric, 0), 'currency', key
  from jsonb_each_text(coalesce(settings_payload->'surcharges', '{}'::jsonb))
  on conflict (pricing_profile_id, setting_key) do update
  set setting_value = excluded.setting_value;

  return profile_id;
end;
$$;

create or replace function public.ttaq_generate_price_from_vehicle_recommendation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.ttaq_generate_price(new.quote_request_id, 0, 0);
  return new;
end;
$$;

drop trigger if exists ttaq_vehicle_recommendation_generate_price on public.vehicle_recommendations;

create trigger ttaq_vehicle_recommendation_generate_price
after insert on public.vehicle_recommendations
for each row execute function public.ttaq_generate_price_from_vehicle_recommendation();
