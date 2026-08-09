create extension if not exists pgcrypto;

create table if not exists public.pricing_seasonal_multipliers (
  id uuid primary key default gen_random_uuid(),
  pricing_profile_id uuid references public.pricing_profiles(id) on delete cascade,
  season_key text not null,
  display_name text not null,
  multiplier numeric(10, 4) not null default 1,
  effective_from date,
  effective_to date,
  is_active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (pricing_profile_id, season_key)
);

create table if not exists public.diesel_price_integrations (
  id uuid primary key default gen_random_uuid(),
  pricing_profile_id uuid references public.pricing_profiles(id) on delete cascade,
  provider_name text not null default 'manual_placeholder',
  provider_status text not null default 'placeholder',
  provider_price_per_litre numeric(14, 4),
  admin_override_price_per_litre numeric(14, 4),
  effective_from date not null default current_date,
  provider_response jsonb not null default '{}'::jsonb,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.toll_cost_rules (
  id uuid primary key default gen_random_uuid(),
  pricing_profile_id uuid references public.pricing_profiles(id) on delete cascade,
  rule_name text not null,
  route_keyword text,
  origin_keyword text,
  destination_keyword text,
  fixed_amount numeric(14, 2) not null default 0,
  amount_per_km numeric(14, 4) not null default 0,
  is_active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.route_risk_pricing_rules (
  id uuid primary key default gen_random_uuid(),
  pricing_profile_id uuid references public.pricing_profiles(id) on delete cascade,
  rule_name text not null,
  risk_level text not null default 'normal',
  route_keyword text,
  origin_keyword text,
  destination_keyword text,
  min_distance_km numeric(14, 2),
  surcharge_percent numeric(10, 4) not null default 0,
  fixed_surcharge numeric(14, 2) not null default 0,
  manager_review_required boolean not null default false,
  is_active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.company_margin_profiles (
  id uuid primary key default gen_random_uuid(),
  pricing_profile_id uuid references public.pricing_profiles(id) on delete cascade,
  margin_key text not null,
  display_name text not null,
  margin_percent numeric(10, 4) not null default 0,
  minimum_profit numeric(14, 2) not null default 0,
  is_default boolean not null default false,
  is_active boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (pricing_profile_id, margin_key)
);

create table if not exists public.monthly_pricing_refreshes (
  id uuid primary key default gen_random_uuid(),
  pricing_profile_id uuid references public.pricing_profiles(id) on delete cascade,
  refresh_month date not null,
  refresh_status text not null default 'pending',
  diesel_provider_status text not null default 'placeholder',
  diesel_price_per_litre numeric(14, 4),
  seasonal_multiplier numeric(10, 4),
  refreshed_by uuid references public.internal_users(id),
  refresh_notes text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create table if not exists public.pricing_calculation_audit_events (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  pricing_calculation_id uuid references public.pricing_calculations(id) on delete cascade,
  event_type text not null,
  event_payload jsonb not null default '{}'::jsonb,
  created_by uuid references public.internal_users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.pricing_component_overrides (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  pricing_calculation_id uuid references public.pricing_calculations(id) on delete set null,
  line_key text not null,
  original_amount numeric(14, 2),
  override_amount numeric(14, 2) not null,
  override_reason text not null,
  overridden_by uuid references public.internal_users(id),
  created_at timestamptz not null default now()
);

alter table public.pricing_calculations
  add column if not exists fuel_price_per_litre numeric(14, 4),
  add column if not exists fuel_surcharge_amount numeric(14, 2) not null default 0,
  add column if not exists seasonal_multiplier numeric(10, 4) not null default 1,
  add column if not exists seasonal_amount numeric(14, 2) not null default 0,
  add column if not exists toll_amount numeric(14, 2) not null default 0,
  add column if not exists route_risk_amount numeric(14, 2) not null default 0,
  add column if not exists margin_profile_key text,
  add column if not exists margin_percent numeric(10, 4),
  add column if not exists dynamic_inputs jsonb not null default '{}'::jsonb,
  add column if not exists dynamic_outputs jsonb not null default '{}'::jsonb,
  add column if not exists manager_review_required boolean not null default false;

drop trigger if exists ttaq_pricing_seasonal_multipliers_touch_updated_at on public.pricing_seasonal_multipliers;
create trigger ttaq_pricing_seasonal_multipliers_touch_updated_at
before update on public.pricing_seasonal_multipliers
for each row execute function public.ttaq_touch_updated_at();

drop trigger if exists ttaq_diesel_price_integrations_touch_updated_at on public.diesel_price_integrations;
create trigger ttaq_diesel_price_integrations_touch_updated_at
before update on public.diesel_price_integrations
for each row execute function public.ttaq_touch_updated_at();

drop trigger if exists ttaq_toll_cost_rules_touch_updated_at on public.toll_cost_rules;
create trigger ttaq_toll_cost_rules_touch_updated_at
before update on public.toll_cost_rules
for each row execute function public.ttaq_touch_updated_at();

drop trigger if exists ttaq_route_risk_pricing_rules_touch_updated_at on public.route_risk_pricing_rules;
create trigger ttaq_route_risk_pricing_rules_touch_updated_at
before update on public.route_risk_pricing_rules
for each row execute function public.ttaq_touch_updated_at();

drop trigger if exists ttaq_company_margin_profiles_touch_updated_at on public.company_margin_profiles;
create trigger ttaq_company_margin_profiles_touch_updated_at
before update on public.company_margin_profiles
for each row execute function public.ttaq_touch_updated_at();

alter table public.pricing_seasonal_multipliers enable row level security;
alter table public.diesel_price_integrations enable row level security;
alter table public.toll_cost_rules enable row level security;
alter table public.route_risk_pricing_rules enable row level security;
alter table public.company_margin_profiles enable row level security;
alter table public.monthly_pricing_refreshes enable row level security;
alter table public.pricing_calculation_audit_events enable row level security;
alter table public.pricing_component_overrides enable row level security;

drop policy if exists "Internal users read seasonal multipliers" on public.pricing_seasonal_multipliers;
create policy "Internal users read seasonal multipliers" on public.pricing_seasonal_multipliers for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
drop policy if exists "Owner manages seasonal multipliers" on public.pricing_seasonal_multipliers;
create policy "Owner manages seasonal multipliers" on public.pricing_seasonal_multipliers for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read diesel integrations" on public.diesel_price_integrations;
create policy "Internal users read diesel integrations" on public.diesel_price_integrations for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
drop policy if exists "Owner manages diesel integrations" on public.diesel_price_integrations;
create policy "Owner manages diesel integrations" on public.diesel_price_integrations for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read toll rules" on public.toll_cost_rules;
create policy "Internal users read toll rules" on public.toll_cost_rules for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
drop policy if exists "Owner manages toll rules" on public.toll_cost_rules;
create policy "Owner manages toll rules" on public.toll_cost_rules for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read risk rules" on public.route_risk_pricing_rules;
create policy "Internal users read risk rules" on public.route_risk_pricing_rules for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
drop policy if exists "Owner manages risk rules" on public.route_risk_pricing_rules;
create policy "Owner manages risk rules" on public.route_risk_pricing_rules for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read margin profiles" on public.company_margin_profiles;
create policy "Internal users read margin profiles" on public.company_margin_profiles for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
drop policy if exists "Owner manages margin profiles" on public.company_margin_profiles;
create policy "Owner manages margin profiles" on public.company_margin_profiles for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read pricing refreshes" on public.monthly_pricing_refreshes;
create policy "Internal users read pricing refreshes" on public.monthly_pricing_refreshes for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
drop policy if exists "Owner manages pricing refreshes" on public.monthly_pricing_refreshes;
create policy "Owner manages pricing refreshes" on public.monthly_pricing_refreshes for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read pricing audit" on public.pricing_calculation_audit_events;
create policy "Internal users read pricing audit" on public.pricing_calculation_audit_events for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
drop policy if exists "Owner and manager manage pricing audit" on public.pricing_calculation_audit_events;
create policy "Owner and manager manage pricing audit" on public.pricing_calculation_audit_events for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

drop policy if exists "Internal users read pricing component overrides" on public.pricing_component_overrides;
create policy "Internal users read pricing component overrides" on public.pricing_component_overrides for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));
drop policy if exists "Owner and manager manage pricing component overrides" on public.pricing_component_overrides;
create policy "Owner and manager manage pricing component overrides" on public.pricing_component_overrides for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create index if not exists ttaq_diesel_price_integrations_profile_effective_idx on public.diesel_price_integrations(pricing_profile_id, effective_from desc);
create index if not exists ttaq_pricing_audit_quote_idx on public.pricing_calculation_audit_events(quote_request_id, created_at desc);
create index if not exists ttaq_pricing_component_overrides_quote_idx on public.pricing_component_overrides(quote_request_id, created_at desc);

insert into public.pricing_settings (pricing_profile_id, setting_key, setting_value, setting_unit, description)
select p.id, defaults.setting_key, defaults.setting_value, defaults.setting_unit, defaults.description
from public.pricing_profiles p
cross join (
  values
    ('diesel_base_price_per_litre', 24.0000, 'ZAR/L', 'Baseline diesel price used for automatic fuel surcharge'),
    ('fuel_surcharge_enabled', 1.0000, 'boolean', 'Enable automatic fuel surcharge calculation'),
    ('seasonal_low_multiplier', 0.9500, 'multiplier', 'Low season multiplier'),
    ('seasonal_normal_multiplier', 1.0000, 'multiplier', 'Normal season multiplier'),
    ('seasonal_busy_multiplier', 1.1000, 'multiplier', 'Busy season multiplier'),
    ('seasonal_peak_multiplier', 1.2000, 'multiplier', 'Peak season multiplier'),
    ('default_toll_cost', 0.0000, 'currency', 'Fallback toll cost placeholder'),
    ('default_route_risk_surcharge', 0.0000, 'currency', 'Fallback route risk surcharge placeholder')
) as defaults(setting_key, setting_value, setting_unit, description)
where p.is_active
on conflict (pricing_profile_id, setting_key) do update
set setting_value = excluded.setting_value,
    setting_unit = excluded.setting_unit,
    description = excluded.description;

insert into public.pricing_seasonal_multipliers (pricing_profile_id, season_key, display_name, multiplier, is_active, notes)
select p.id, season_key, display_name, multiplier, true, notes
from public.pricing_profiles p
cross join (
  values
    ('low', 'Low season', 0.9500, 'Starter seasonal profile'),
    ('normal', 'Normal season', 1.0000, 'Default active seasonal profile'),
    ('busy', 'Busy season', 1.1000, 'Starter seasonal profile'),
    ('peak', 'Peak season', 1.2000, 'Starter seasonal profile')
) as defaults(season_key, display_name, multiplier, notes)
where p.is_active
on conflict (pricing_profile_id, season_key) do update
set display_name = excluded.display_name,
    multiplier = excluded.multiplier,
    is_active = excluded.is_active,
    notes = excluded.notes;

insert into public.company_margin_profiles (pricing_profile_id, margin_key, display_name, margin_percent, minimum_profit, is_default, is_active, notes)
select p.id, margin_key, display_name, margin_percent, minimum_profit, is_default, true, notes
from public.pricing_profiles p
cross join (
  values
    ('minimum', 'Minimum margin', 15.0000, 1200.00, false, 'Use only with manager approval'),
    ('target', 'Target margin', 20.0000, 1500.00, true, 'Default Time Trucking margin profile'),
    ('premium', 'Premium margin', 28.0000, 2500.00, false, 'High demand or specialist transport profile')
) as defaults(margin_key, display_name, margin_percent, minimum_profit, is_default, notes)
where p.is_active
on conflict (pricing_profile_id, margin_key) do update
set display_name = excluded.display_name,
    margin_percent = excluded.margin_percent,
    minimum_profit = excluded.minimum_profit,
    is_default = excluded.is_default,
    is_active = excluded.is_active,
    notes = excluded.notes;

insert into public.diesel_price_integrations (pricing_profile_id, provider_name, provider_status, admin_override_price_per_litre, effective_from, provider_response)
select p.id, 'manual_admin_override', 'placeholder', 24.0000, current_date, jsonb_build_object('note', 'Live diesel provider not configured yet')
from public.pricing_profiles p
where p.is_active
  and not exists (
    select 1 from public.diesel_price_integrations d
    where d.pricing_profile_id = p.id
  );

create or replace function public.ttaq_current_diesel_price(profile_id uuid)
returns numeric
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((
    select coalesce(admin_override_price_per_litre, provider_price_per_litre)
    from public.diesel_price_integrations
    where pricing_profile_id = profile_id
      and effective_from <= current_date
    order by effective_from desc, created_at desc
    limit 1
  ), (
    select fuel_price_per_litre
    from public.fuel_price_history
    where pricing_profile_id = profile_id
    order by effective_from desc, created_at desc
    limit 1
  ), 0);
$$;

create or replace function public.ttaq_active_seasonal_multiplier(profile_id uuid)
returns table(season_key text, multiplier numeric)
language sql
security definer
set search_path = public
stable
as $$
  select sm.season_key, sm.multiplier
  from public.pricing_seasonal_multipliers sm
  where sm.pricing_profile_id = profile_id
    and sm.is_active
    and (sm.effective_from is null or sm.effective_from <= current_date)
    and (sm.effective_to is null or sm.effective_to >= current_date)
  order by
    case when sm.season_key = 'normal' then 1 else 0 end,
    coalesce(sm.effective_from, date '1900-01-01') desc,
    sm.created_at desc
  limit 1;
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
  rule_version_value text := 'pricing-v2-dynamic';
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
      vehicle_type = coalesce(recommendation.override_vehicle_type, recommendation.recommended_vehicle_type)
      or vehicle_type = 'default'
    )
  order by case when vehicle_type = coalesce(recommendation.override_vehicle_type, recommendation.recommended_vehicle_type) then 0 else 1 end
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

  overnight_count := floor(coalesce(estimated_duration_hours, 0) / 24);

  fuel_amount := round(coalesce(estimated_distance_km, 0) * (coalesce(vehicle_cost.fuel_consumption_l_per_100km, 0) / 100) * coalesce(fuel_price, 0), 2);
  fuel_surcharge_percent := case
    when fuel_surcharge_enabled and diesel_base_price is not null and fuel_price > diesel_base_price
      then round(((fuel_price - diesel_base_price) / diesel_base_price) * 100, 4)
    else 0
  end;
  fuel_surcharge_amount := round(fuel_amount * (fuel_surcharge_percent / 100), 2);
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
    calculation_notes,
    fuel_price_per_litre,
    fuel_surcharge_amount,
    seasonal_multiplier,
    seasonal_amount,
    toll_amount,
    route_risk_amount,
    margin_profile_key,
    margin_percent,
    dynamic_inputs,
    dynamic_outputs,
    manager_review_required
  )
  values (
    target_quote_request_id,
    recommendation.id,
    profile_id,
    coalesce(rule_version_value, 'pricing-v2-dynamic'),
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
    'Dynamic pricing generated from diesel, route, seasonal, vehicle cost, and margin profile rules.',
    fuel_price,
    fuel_surcharge_amount,
    seasonal_multiplier_value,
    seasonal_amount,
    toll_amount,
    route_risk_amount,
    margin_profile.margin_key,
    coalesce(margin_profile.margin_percent, overhead.profit_margin_percent, 0),
    jsonb_build_object(
      'diesel_price_per_litre', fuel_price,
      'diesel_base_price_per_litre', diesel_base_price,
      'fuel_surcharge_percent', fuel_surcharge_percent,
      'seasonal_key', seasonal_key,
      'seasonal_multiplier', seasonal_multiplier_value,
      'margin_profile', margin_profile.margin_key,
      'route_provider', route_record.provider_name
    ),
    jsonb_build_object(
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
    (calculation_id, target_quote_request_id, 'fuel', 'Fuel', coalesce(estimated_distance_km, 0), fuel_price, fuel_amount, 'Distance x vehicle fuel consumption x current diesel price'),
    (calculation_id, target_quote_request_id, 'fuel_surcharge', 'Fuel surcharge', fuel_amount, fuel_surcharge_percent, fuel_surcharge_amount, 'Automatic surcharge when current diesel is above configured baseline'),
    (calculation_id, target_quote_request_id, 'driver', 'Driver', coalesce(estimated_duration_hours, 0), coalesce(driver_cost.driver_hourly_wage, 0), driver_amount + overnight_amount, 'Driver wages plus overnight allowance'),
    (calculation_id, target_quote_request_id, 'maintenance', 'Maintenance', coalesce(estimated_distance_km, 0), coalesce(vehicle_cost.maintenance_cost_per_km, 0), maintenance_amount, 'Distance x maintenance cost/km'),
    (calculation_id, target_quote_request_id, 'tyres', 'Tyres', coalesce(estimated_distance_km, 0), coalesce(vehicle_cost.average_tyre_cost_per_km, 0), tyres_amount, 'Distance x tyre cost/km'),
    (calculation_id, target_quote_request_id, 'insurance', 'Insurance', coalesce(estimated_distance_km, 0), coalesce(vehicle_cost.insurance_cost_per_km, 0), insurance_amount, 'Distance x insurance cost/km'),
    (calculation_id, target_quote_request_id, 'depreciation', 'Depreciation', coalesce(estimated_distance_km, 0), coalesce(vehicle_cost.depreciation_cost_per_km, 0), depreciation_amount, 'Distance x depreciation cost/km'),
    (calculation_id, target_quote_request_id, 'tolls', 'Tolls', coalesce(estimated_distance_km, 0), toll_amount, toll_amount, 'Configurable toll framework rules matched against the route'),
    (calculation_id, target_quote_request_id, 'route_risk', 'Route risk', base_cost_value, 0, route_risk_amount, 'Configurable route risk rules matched against distance and route text'),
    (calculation_id, target_quote_request_id, 'seasonal_multiplier', 'Seasonal multiplier', base_cost_value, seasonal_multiplier_value, seasonal_amount, 'Seasonal multiplier applied from active pricing profile'),
    (calculation_id, target_quote_request_id, 'overhead', 'Overhead', subtotal_value, coalesce(overhead.admin_overhead_percent, 0), company_overhead_amount + vehicle_overhead_amount, 'Vehicle overhead plus company admin overhead'),
    (calculation_id, target_quote_request_id, 'escort', 'Escort', 1, escort_amount, escort_amount, 'Configurable escort surcharge when recommended'),
    (calculation_id, target_quote_request_id, 'permit', 'Permit', 1, permit_amount, permit_amount, 'Configurable permit surcharge when required'),
    (calculation_id, target_quote_request_id, 'hazmat', 'Hazmat', 1, hazmat_amount, hazmat_amount, 'Configurable dangerous goods surcharge'),
    (calculation_id, target_quote_request_id, 'refrigeration', 'Refrigeration', 1, refrigeration_amount, refrigeration_amount, 'Configurable refrigeration surcharge'),
    (calculation_id, target_quote_request_id, 'crane', 'Crane', 1, crane_amount, crane_amount, 'Configurable crane surcharge'),
    (calculation_id, target_quote_request_id, 'forklift', 'Forklift', 1, forklift_amount, forklift_amount, 'Configurable forklift surcharge'),
    (calculation_id, target_quote_request_id, 'high_value', 'High-value cargo', 1, high_value_amount, high_value_amount, 'Configurable surcharge when cargo value exceeds threshold'),
    (calculation_id, target_quote_request_id, 'profit', 'Margin / profit', subtotal_value, coalesce(margin_profile.margin_percent, overhead.profit_margin_percent, 0), profit_value, 'Company margin profile with minimum profit applied'),
    (calculation_id, target_quote_request_id, 'vat', 'VAT', subtotal_value + profit_value, coalesce(overhead.vat_percent, 0), vat_value, 'VAT applied after profit');

  insert into public.pricing_calculation_audit_events (quote_request_id, pricing_calculation_id, event_type, event_payload, created_by)
  values (
    target_quote_request_id,
    calculation_id,
    'dynamic_price_generated',
    jsonb_build_object(
      'rule_version', coalesce(rule_version_value, 'pricing-v2-dynamic'),
      'recommended_selling_price', grand_total_value,
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

create or replace function public.ttaq_record_pricing_component_override(
  target_quote_request_id uuid,
  target_pricing_calculation_id uuid,
  line_key_value text,
  override_amount_value numeric,
  override_reason_value text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  original_amount_value numeric;
  override_id uuid;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Not allowed to override pricing components';
  end if;

  if nullif(override_reason_value, '') is null then
    raise exception 'Override reason is required';
  end if;

  select amount into original_amount_value
  from public.pricing_breakdowns
  where pricing_calculation_id = target_pricing_calculation_id
    and line_key = line_key_value
  order by created_at desc
  limit 1;

  insert into public.pricing_component_overrides (
    quote_request_id,
    pricing_calculation_id,
    line_key,
    original_amount,
    override_amount,
    override_reason,
    overridden_by
  )
  values (
    target_quote_request_id,
    target_pricing_calculation_id,
    line_key_value,
    original_amount_value,
    override_amount_value,
    override_reason_value,
    auth.uid()
  )
  returning id into override_id;

  insert into public.pricing_calculation_audit_events (quote_request_id, pricing_calculation_id, event_type, event_payload, created_by)
  values (
    target_quote_request_id,
    target_pricing_calculation_id,
    'component_override_recorded',
    jsonb_build_object('line_key', line_key_value, 'original_amount', original_amount_value, 'override_amount', override_amount_value, 'reason', override_reason_value),
    auth.uid()
  );

  return override_id;
end;
$$;

create or replace function public.ttaq_record_monthly_pricing_refresh(
  refresh_notes_value text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_id uuid;
  refresh_id uuid;
  diesel_price numeric;
  seasonal_value numeric;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules') then
    raise exception 'Not allowed to refresh pricing settings';
  end if;

  profile_id := public.ttaq_active_pricing_profile();
  diesel_price := public.ttaq_current_diesel_price(profile_id);

  select multiplier into seasonal_value
  from public.ttaq_active_seasonal_multiplier(profile_id);

  insert into public.monthly_pricing_refreshes (
    pricing_profile_id,
    refresh_month,
    refresh_status,
    diesel_provider_status,
    diesel_price_per_litre,
    seasonal_multiplier,
    refreshed_by,
    refresh_notes,
    completed_at
  )
  values (
    profile_id,
    date_trunc('month', current_date)::date,
    'completed_placeholder',
    'placeholder',
    diesel_price,
    seasonal_value,
    auth.uid(),
    coalesce(refresh_notes_value, 'Monthly pricing refresh placeholder recorded. Live diesel API integration remains future work.'),
    now()
  )
  returning id into refresh_id;

  return refresh_id;
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
      coalesce(settings_payload->>'rule_version', 'pricing-v2-dynamic')
    )
    returning id into profile_id;
  else
    update public.pricing_profiles
       set currency = coalesce(settings_payload->>'currency', currency),
           quote_validity_days = coalesce(nullif(settings_payload->>'quote_validity_days', '')::integer, quote_validity_days),
           rule_version = coalesce(settings_payload->>'rule_version', 'pricing-v2-dynamic')
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
    provider_response
  )
  values (
    profile_id,
    'manual_admin_override',
    'placeholder',
    null,
    coalesce(nullif(settings_payload->>'diesel_admin_override_price_per_litre', '')::numeric, nullif(settings_payload->>'fuel_price_per_litre', '')::numeric, 0),
    current_date,
    jsonb_build_object('source', 'pricing_settings_page', 'live_provider_configured', false)
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
    (profile_id, 'default_route_risk_surcharge', coalesce(nullif(settings_payload->>'default_route_risk_surcharge', '')::numeric, 0), 'currency', 'Fallback route risk amount')
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
