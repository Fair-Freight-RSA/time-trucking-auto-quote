create table if not exists public.vehicle_class_internal_cost_profiles (
  id uuid primary key default gen_random_uuid(),
  pricing_profile_id uuid not null references public.pricing_profiles(id) on delete cascade,
  vehicle_class_key text not null,
  display_name text not null,
  effective_from date not null default current_date,
  effective_to date,
  source_basis text not null default 'Requires Time Trucking input',
  notes text,
  profile_status text not null default 'requires_input',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint vehicle_class_internal_cost_profiles_key_check check (vehicle_class_key in ('1_ton', '1_8_ton', '3_ton', '5_ton', '8_ton', '12_ton', 'semi', 'superlink')),
  constraint vehicle_class_internal_cost_profiles_status_check check (profile_status in ('confirmed', 'estimated', 'partial', 'requires_input', 'inactive')),
  constraint vehicle_class_internal_cost_profiles_period_check check (effective_to is null or effective_to >= effective_from),
  unique (pricing_profile_id, vehicle_class_key, effective_from)
);

create table if not exists public.vehicle_class_internal_cost_components (
  id uuid primary key default gen_random_uuid(),
  cost_profile_id uuid not null references public.vehicle_class_internal_cost_profiles(id) on delete cascade,
  component_key text not null,
  display_name text not null,
  unit_code text not null,
  amount numeric(14, 4),
  value_status text not null default 'not_configured',
  source_type text not null default 'requires_time_trucking_input',
  source_basis text not null default 'Requires Time Trucking input',
  is_required boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint vehicle_class_internal_cost_components_key_check check (component_key in ('fuel_consumption_l_per_100km', 'tyres_per_km', 'maintenance_per_km', 'insurance_per_km', 'depreciation_per_km', 'vehicle_overhead_per_km', 'driver_hourly_cost', 'night_out_allowance')),
  constraint vehicle_class_internal_cost_components_status_check check (value_status in ('confirmed', 'estimated', 'inherited', 'manual_configured', 'not_configured')),
  constraint vehicle_class_internal_cost_components_source_check check (source_type in ('vehicle_class_specific', 'equipment_override', 'company_default', 'shared_default', 'legacy_generic_fallback', 'requires_time_trucking_input')),
  constraint vehicle_class_internal_cost_components_amount_check check (amount is null or amount >= 0),
  unique (cost_profile_id, component_key)
);

create table if not exists public.equipment_internal_cost_profile_overrides (
  id uuid primary key default gen_random_uuid(),
  equipment_profile_id uuid not null references public.standard_equipment_profiles(id) on delete cascade,
  cost_profile_id uuid not null references public.vehicle_class_internal_cost_profiles(id) on delete restrict,
  source_basis text not null,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (equipment_profile_id, is_active)
);

alter table public.standard_equipment_profiles
  add column if not exists internal_cost_vehicle_class_key text,
  add column if not exists internal_cost_profile_mapping_status text not null default 'requires_confirmation',
  add column if not exists internal_cost_profile_mapping_source text,
  add constraint standard_equipment_profiles_internal_cost_class_check
    check (internal_cost_vehicle_class_key is null or internal_cost_vehicle_class_key in ('1_ton', '1_8_ton', '3_ton', '5_ton', '8_ton', '12_ton', 'semi', 'superlink')),
  add constraint standard_equipment_profiles_internal_cost_mapping_status_check
    check (internal_cost_profile_mapping_status in ('mapped', 'override', 'requires_confirmation'));

drop trigger if exists ttaq_vehicle_class_internal_cost_profiles_touch_updated_at on public.vehicle_class_internal_cost_profiles;
create trigger ttaq_vehicle_class_internal_cost_profiles_touch_updated_at
before update on public.vehicle_class_internal_cost_profiles
for each row execute function public.ttaq_touch_updated_at();

drop trigger if exists ttaq_vehicle_class_internal_cost_components_touch_updated_at on public.vehicle_class_internal_cost_components;
create trigger ttaq_vehicle_class_internal_cost_components_touch_updated_at
before update on public.vehicle_class_internal_cost_components
for each row execute function public.ttaq_touch_updated_at();

drop trigger if exists ttaq_equipment_internal_cost_profile_overrides_touch_updated_at on public.equipment_internal_cost_profile_overrides;
create trigger ttaq_equipment_internal_cost_profile_overrides_touch_updated_at
before update on public.equipment_internal_cost_profile_overrides
for each row execute function public.ttaq_touch_updated_at();

alter table public.vehicle_class_internal_cost_profiles enable row level security;
alter table public.vehicle_class_internal_cost_components enable row level security;
alter table public.equipment_internal_cost_profile_overrides enable row level security;

drop policy if exists "Internal users read vehicle class internal costs" on public.vehicle_class_internal_cost_profiles;
create policy "Internal users read vehicle class internal costs"
on public.vehicle_class_internal_cost_profiles for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

drop policy if exists "Pricing managers manage vehicle class internal costs" on public.vehicle_class_internal_cost_profiles;
create policy "Pricing managers manage vehicle class internal costs"
on public.vehicle_class_internal_cost_profiles for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read vehicle class internal cost components" on public.vehicle_class_internal_cost_components;
create policy "Internal users read vehicle class internal cost components"
on public.vehicle_class_internal_cost_components for select
using (
  exists (
    select 1
    from public.vehicle_class_internal_cost_profiles profile
    where profile.id = vehicle_class_internal_cost_components.cost_profile_id
      and (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
  )
);

drop policy if exists "Pricing managers manage vehicle class internal cost components" on public.vehicle_class_internal_cost_components;
create policy "Pricing managers manage vehicle class internal cost components"
on public.vehicle_class_internal_cost_components for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read equipment internal cost overrides" on public.equipment_internal_cost_profile_overrides;
create policy "Internal users read equipment internal cost overrides"
on public.equipment_internal_cost_profile_overrides for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

drop policy if exists "Pricing managers manage equipment internal cost overrides" on public.equipment_internal_cost_profile_overrides;
create policy "Pricing managers manage equipment internal cost overrides"
on public.equipment_internal_cost_profile_overrides for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

with active_profile as (
  select public.ttaq_active_pricing_profile() as id
),
classes(vehicle_class_key, display_name) as (
  values
    ('1_ton', '1 Ton'),
    ('1_8_ton', '1.8 Ton'),
    ('3_ton', '3 Ton'),
    ('5_ton', '5 Ton'),
    ('8_ton', '8 Ton'),
    ('12_ton', '12 Ton'),
    ('semi', 'Semi'),
    ('superlink', 'S/L')
),
seeded_profiles as (
  insert into public.vehicle_class_internal_cost_profiles (
    pricing_profile_id, vehicle_class_key, display_name, effective_from, source_basis, notes, profile_status, is_active
  )
  select active_profile.id, classes.vehicle_class_key, classes.display_name, date '2026-08-16',
         'Requires Time Trucking input',
         'Vehicle-class internal operating-cost profile created without invented values. NULL means not configured; it is not a confirmed zero.',
         'requires_input',
         true
  from active_profile
  cross join classes
  where active_profile.id is not null
  on conflict (pricing_profile_id, vehicle_class_key, effective_from) do update
  set display_name = excluded.display_name,
      source_basis = excluded.source_basis,
      notes = excluded.notes,
      is_active = true,
      updated_at = now()
  returning id, vehicle_class_key
),
component_defs(component_key, display_name, unit_code, is_required) as (
  values
    ('fuel_consumption_l_per_100km', 'Fuel consumption', 'L/100km', true),
    ('tyres_per_km', 'Tyres', 'R/km', true),
    ('maintenance_per_km', 'Maintenance', 'R/km', true),
    ('insurance_per_km', 'Insurance', 'R/km', true),
    ('depreciation_per_km', 'Depreciation', 'R/km', true),
    ('vehicle_overhead_per_km', 'Vehicle overhead', 'R/km', true),
    ('driver_hourly_cost', 'Driver hourly cost', 'R/hour', true),
    ('night_out_allowance', 'Night-out allowance', 'R/night', false)
)
insert into public.vehicle_class_internal_cost_components (
  cost_profile_id, component_key, display_name, unit_code, amount, value_status, source_type, source_basis, is_required
)
select profile.id, defs.component_key, defs.display_name, defs.unit_code,
       case when defs.component_key = 'night_out_allowance' then 1750::numeric else null::numeric end,
       case when defs.component_key = 'night_out_allowance' then 'inherited' else 'not_configured' end,
       case when defs.component_key = 'night_out_allowance' then 'company_default' else 'requires_time_trucking_input' end,
       case when defs.component_key = 'night_out_allowance' then 'Time Trucking company default confirmed at R1,750 per applicable driver night out; automatic trigger still requires Henning confirmation.' else 'Requires Time Trucking input' end,
       defs.is_required
from seeded_profiles profile
cross join component_defs defs
on conflict (cost_profile_id, component_key) do nothing;

update public.standard_equipment_profiles
   set internal_cost_vehicle_class_key = case
         when equipment_code = 'bakkie-panel-1t' then '1_ton'
         when equipment_code = 'rigid-8t-tautliner' then '8_ton'
         when equipment_code in ('tri-axle-tautliner', 'tri-axle-flatdeck', 'reefer-trailer') then 'semi'
         when equipment_code in ('superlink-tautliner', 'superlink-flatdeck') then 'superlink'
         else null
       end,
       internal_cost_profile_mapping_status = case
         when equipment_code in ('bakkie-panel-1t', 'rigid-8t-tautliner', 'tri-axle-tautliner', 'tri-axle-flatdeck', 'reefer-trailer', 'superlink-tautliner', 'superlink-flatdeck') then 'mapped'
         else 'requires_confirmation'
       end,
       internal_cost_profile_mapping_source = case
         when equipment_code = 'bakkie-panel-1t' then 'Mapped to Time Trucking 1 Ton class.'
         when equipment_code = 'rigid-8t-tautliner' then 'Mapped to Time Trucking 8 Ton class.'
         when equipment_code in ('tri-axle-tautliner', 'tri-axle-flatdeck', 'reefer-trailer') then 'Mapped to Time Trucking Semi class; specialist overrides remain supported.'
         when equipment_code in ('superlink-tautliner', 'superlink-flatdeck') then 'Mapped to Time Trucking S/L class.'
         else 'Internal cost profile mapping requires confirmation.'
       end
 where is_active;

create or replace function public.ttaq_vehicle_class_internal_cost_profile_summary()
returns table (
  profile_id uuid,
  vehicle_class_key text,
  display_name text,
  effective_from date,
  effective_to date,
  profile_status text,
  source_basis text,
  notes text,
  is_active boolean,
  updated_at timestamptz,
  components jsonb,
  missing_required_components text[]
)
language sql
security definer
set search_path = public
as $$
  with current_profiles as (
    select distinct on (profile.vehicle_class_key)
           profile.*
    from public.vehicle_class_internal_cost_profiles profile
    where profile.pricing_profile_id = public.ttaq_active_pricing_profile()
      and profile.is_active
      and profile.effective_from <= current_date
      and (profile.effective_to is null or profile.effective_to >= current_date)
    order by profile.vehicle_class_key, profile.effective_from desc, profile.created_at desc
  )
  select profile.id,
         profile.vehicle_class_key,
         profile.display_name,
         profile.effective_from,
         profile.effective_to,
         profile.profile_status,
         profile.source_basis,
         profile.notes,
         profile.is_active,
         profile.updated_at,
         coalesce(jsonb_agg(
           jsonb_build_object(
             'component_key', component.component_key,
             'display_name', component.display_name,
             'unit_code', component.unit_code,
             'amount', component.amount,
             'value_status', component.value_status,
             'source_type', component.source_type,
             'source_basis', component.source_basis,
             'is_required', component.is_required
           )
           order by case component.component_key
             when 'fuel_consumption_l_per_100km' then 1
             when 'tyres_per_km' then 2
             when 'maintenance_per_km' then 3
             when 'insurance_per_km' then 4
             when 'depreciation_per_km' then 5
             when 'vehicle_overhead_per_km' then 6
             when 'driver_hourly_cost' then 7
             when 'night_out_allowance' then 8
             else 99
           end
         ), '[]'::jsonb) as components,
         coalesce(array_agg(component.display_name order by component.display_name) filter (
           where component.is_required and (component.amount is null or component.value_status = 'not_configured')
         ), array[]::text[]) as missing_required_components
  from current_profiles profile
  left join public.vehicle_class_internal_cost_components component on component.cost_profile_id = profile.id
  group by profile.id, profile.vehicle_class_key, profile.display_name, profile.effective_from,
           profile.effective_to, profile.profile_status, profile.source_basis, profile.notes,
           profile.is_active, profile.updated_at
  order by case profile.vehicle_class_key
    when '1_ton' then 1
    when '1_8_ton' then 2
    when '3_ton' then 3
    when '5_ton' then 4
    when '8_ton' then 5
    when '12_ton' then 6
    when 'semi' then 7
    when 'superlink' then 8
    else 99
  end;
$$;

grant execute on function public.ttaq_vehicle_class_internal_cost_profile_summary() to authenticated;

create or replace function public.ttaq_recalculate_internal_cost_analysis(target_pricing_calculation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  calculation public.pricing_calculations%rowtype;
  vehicle_class_key_value text;
  cost_profile public.vehicle_class_internal_cost_profiles%rowtype;
  component_map jsonb := '{}'::jsonb;
  missing_components text[] := array[]::text[];
  distance_value numeric := 0;
  duration_value numeric := 0;
  unit_count_value numeric := 1;
  diesel_price_value numeric := 0;
  night_out_count_value numeric := 0;
  fuel_litres numeric := null;
  fuel_amount_value numeric := null;
  tyres_amount_value numeric := null;
  maintenance_amount_value numeric := null;
  insurance_amount_value numeric := null;
  depreciation_amount_value numeric := null;
  overhead_amount_value numeric := null;
  driver_amount_value numeric := null;
  night_out_amount_value numeric := 0;
  internal_total numeric := null;
  contribution_value numeric := null;
  contribution_percent_value numeric := null;
  is_complete boolean := false;
  component record;
begin
  select * into calculation
  from public.pricing_calculations
  where id = target_pricing_calculation_id;

  if calculation.id is null or calculation.rule_version not like '%commercial-rate-card%' then
    return;
  end if;

  vehicle_class_key_value := coalesce(
    calculation.pricing_source_snapshot #>> '{equipment,internal_cost_vehicle_class_key}',
    (
      select equipment.internal_cost_vehicle_class_key
      from public.standard_equipment_profiles equipment
      where equipment.id = nullif(calculation.pricing_source_snapshot #>> '{equipment,selected_equipment_profile_id}', '')::uuid
      limit 1
    ),
    calculation.pricing_source_snapshot #>> '{equipment,rate_category_key}'
  );

  select profile.* into cost_profile
  from public.vehicle_class_internal_cost_profiles profile
  where profile.pricing_profile_id = calculation.pricing_profile_id
    and profile.vehicle_class_key = vehicle_class_key_value
    and profile.is_active
    and profile.effective_from <= current_date
    and (profile.effective_to is null or profile.effective_to >= current_date)
  order by profile.effective_from desc, profile.created_at desc
  limit 1;

  if cost_profile.id is null then
    missing_components := array['Internal cost profile mapping requires confirmation'];
  else
    for component in
      select *
      from public.vehicle_class_internal_cost_components
      where cost_profile_id = cost_profile.id
    loop
      component_map := component_map || jsonb_build_object(
        component.component_key,
        jsonb_build_object(
          'amount', component.amount,
          'unit_code', component.unit_code,
          'value_status', component.value_status,
          'source_type', component.source_type,
          'source_basis', component.source_basis
        )
      );
      if component.is_required and (component.amount is null or component.value_status = 'not_configured') then
        missing_components := array_append(missing_components, cost_profile.display_name || ' ' || component.display_name || ' (' || component.unit_code || ')');
      end if;
    end loop;
  end if;

  distance_value := coalesce(calculation.estimated_distance_km, 0);
  duration_value := coalesce(calculation.estimated_duration_hours, 0);
  unit_count_value := greatest(1, coalesce(nullif((calculation.dynamic_outputs->>'vehicle_dependent_costs_multiplier')::numeric, 0), 1));
  diesel_price_value := coalesce(calculation.fuel_price_per_litre, (calculation.dynamic_outputs->>'diesel_current_price_per_litre')::numeric, 0);
  night_out_count_value := greatest(0, coalesce((calculation.dynamic_outputs->>'night_out_count')::numeric, 0));

  is_complete := array_length(missing_components, 1) is null;

  if is_complete then
    fuel_litres := round(distance_value * ((component_map #>> '{fuel_consumption_l_per_100km,amount}')::numeric / 100) * unit_count_value, 4);
    fuel_amount_value := round(fuel_litres * diesel_price_value, 2);
    tyres_amount_value := round(distance_value * (component_map #>> '{tyres_per_km,amount}')::numeric * unit_count_value, 2);
    maintenance_amount_value := round(distance_value * (component_map #>> '{maintenance_per_km,amount}')::numeric * unit_count_value, 2);
    insurance_amount_value := round(distance_value * (component_map #>> '{insurance_per_km,amount}')::numeric * unit_count_value, 2);
    depreciation_amount_value := round(distance_value * (component_map #>> '{depreciation_per_km,amount}')::numeric * unit_count_value, 2);
    overhead_amount_value := round(distance_value * (component_map #>> '{vehicle_overhead_per_km,amount}')::numeric * unit_count_value, 2);
    driver_amount_value := round(duration_value * (component_map #>> '{driver_hourly_cost,amount}')::numeric * unit_count_value, 2);
    night_out_amount_value := round(night_out_count_value * coalesce((component_map #>> '{night_out_allowance,amount}')::numeric, 1750) * unit_count_value, 2);
    internal_total := fuel_amount_value + tyres_amount_value + maintenance_amount_value + insurance_amount_value + depreciation_amount_value + overhead_amount_value + driver_amount_value + night_out_amount_value;
    contribution_value := round(coalesce(calculation.subtotal, 0) - internal_total, 2);
    contribution_percent_value := case when coalesce(calculation.subtotal, 0) > 0 then round((contribution_value / calculation.subtotal) * 100, 4) else null end;
  end if;

  update public.pricing_calculations
     set dynamic_outputs = coalesce(dynamic_outputs, '{}'::jsonb)
       || jsonb_build_object(
            'internal_cost_analysis_status', case when is_complete then 'complete' else 'incomplete' end,
            'internal_cost_missing_components', to_jsonb(missing_components),
            'fuel_litres', fuel_litres,
            'fuel_amount', fuel_amount_value,
            'tyres_amount', tyres_amount_value,
            'maintenance_amount', maintenance_amount_value,
            'vehicle_insurance_amount', insurance_amount_value,
            'depreciation_amount', depreciation_amount_value,
            'driver_amount', driver_amount_value,
            'internal_vehicle_overhead_amount', overhead_amount_value,
            'internal_night_out_amount', night_out_amount_value,
            'estimated_internal_operating_cost', internal_total,
            'estimated_contribution_before_vat', contribution_value,
            'estimated_contribution_percent', contribution_percent_value,
            'internal_cost_label', case when is_complete then 'Estimated internal operating cost' else 'Internal cost analysis incomplete' end
          ),
         pricing_source_snapshot = coalesce(pricing_source_snapshot, '{}'::jsonb)
       || jsonb_build_object(
            'internal_cost_analysis',
            jsonb_build_object(
              'status', case when is_complete then 'complete' else 'incomplete' end,
              'vehicle_class_key', vehicle_class_key_value,
              'vehicle_cost_profile', cost_profile.display_name,
              'cost_profile_id', cost_profile.id,
              'components', component_map,
              'missing_components', to_jsonb(missing_components),
              'fuel_formula', 'distance_km x vehicle-specific L/100km / 100 x unit_count x current diesel price',
              'distance_cost_formula', 'distance_km x vehicle-class R/km cost x unit_count',
              'driver_formula', 'duration_hours x driver hourly rate x unit_count',
              'night_out_formula', 'night_out_count x R1,750 company default or vehicle override x applicable driver count',
              'estimated_internal_operating_cost', internal_total,
              'estimated_contribution_before_vat', contribution_value,
              'estimated_contribution_percent', contribution_percent_value,
              'selling_price_effect', 'Internal operating costs do not increase the customer selling price'
            )
          )
   where id = target_pricing_calculation_id;

  update public.pricing_breakdowns
     set amount = case line_key
           when 'internal_fuel' then coalesce(fuel_amount_value, 0)
           when 'internal_tyres' then coalesce(tyres_amount_value, 0)
           when 'internal_maintenance' then coalesce(maintenance_amount_value, 0)
           when 'internal_insurance' then coalesce(insurance_amount_value, 0)
           when 'internal_depreciation' then coalesce(depreciation_amount_value, 0)
           when 'internal_driver' then coalesce(driver_amount_value, 0)
           when 'internal_vehicle_overhead' then coalesce(overhead_amount_value, 0)
           else amount
         end,
         unit_rate = case line_key
           when 'internal_fuel' then coalesce((component_map #>> '{fuel_consumption_l_per_100km,amount}')::numeric, 0)
           when 'internal_tyres' then coalesce((component_map #>> '{tyres_per_km,amount}')::numeric, 0)
           when 'internal_maintenance' then coalesce((component_map #>> '{maintenance_per_km,amount}')::numeric, 0)
           when 'internal_insurance' then coalesce((component_map #>> '{insurance_per_km,amount}')::numeric, 0)
           when 'internal_depreciation' then coalesce((component_map #>> '{depreciation_per_km,amount}')::numeric, 0)
           when 'internal_driver' then coalesce((component_map #>> '{driver_hourly_cost,amount}')::numeric, 0)
           when 'internal_vehicle_overhead' then coalesce((component_map #>> '{vehicle_overhead_per_km,amount}')::numeric, 0)
           else unit_rate
         end,
         explanation = case
           when is_complete then 'Internal operating-cost analysis only: calculated from vehicle-class cost profile ' || coalesce(cost_profile.display_name, vehicle_class_key_value) || '. Does not alter customer selling price.'
           else 'Internal cost analysis incomplete - not available because required vehicle-class internal-cost inputs are missing: ' || array_to_string(missing_components, ', ') || '. Does not alter customer selling price.'
         end
   where pricing_calculation_id = target_pricing_calculation_id
     and line_key in ('internal_fuel', 'internal_tyres', 'internal_maintenance', 'internal_insurance', 'internal_depreciation', 'internal_driver', 'internal_vehicle_overhead');
end;
$$;

create or replace function public.ttaq_after_internal_cost_breakdown_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.line_key in ('internal_fuel', 'internal_tyres', 'internal_maintenance', 'internal_insurance', 'internal_depreciation', 'internal_driver', 'internal_vehicle_overhead') then
    perform public.ttaq_recalculate_internal_cost_analysis(new.pricing_calculation_id);
  end if;
  return new;
end;
$$;

drop trigger if exists ttaq_recalculate_vehicle_class_internal_costs on public.pricing_breakdowns;
create trigger ttaq_recalculate_vehicle_class_internal_costs
after insert on public.pricing_breakdowns
for each row execute function public.ttaq_after_internal_cost_breakdown_insert();

create or replace function public.ttaq_save_vehicle_class_internal_cost_profile(profile_payload jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  active_profile_id uuid := public.ttaq_active_pricing_profile();
  class_key text := profile_payload->>'vehicle_class_key';
  class_label text := coalesce(profile_payload->>'display_name', class_key);
  effective_date date := coalesce(nullif(profile_payload->>'effective_from', '')::date, current_date);
  new_profile_id uuid;
  component jsonb;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules') then
    raise exception 'Not allowed to manage internal operating-cost profiles';
  end if;

  if class_key not in ('1_ton', '1_8_ton', '3_ton', '5_ton', '8_ton', '12_ton', 'semi', 'superlink') then
    raise exception 'Unknown Time Trucking vehicle class';
  end if;

  update public.vehicle_class_internal_cost_profiles
     set is_active = false,
         effective_to = effective_date - 1,
         profile_status = 'inactive',
         updated_at = now()
   where pricing_profile_id = active_profile_id
     and vehicle_class_key = class_key
     and is_active
     and effective_from < effective_date;

  insert into public.vehicle_class_internal_cost_profiles (
    pricing_profile_id, vehicle_class_key, display_name, effective_from, source_basis, notes, profile_status, is_active
  )
  values (
    active_profile_id,
    class_key,
    class_label,
    effective_date,
    coalesce(profile_payload->>'source_basis', 'Manually configured by Time Trucking'),
    profile_payload->>'notes',
    coalesce(profile_payload->>'profile_status', 'partial'),
    true
  )
  on conflict (pricing_profile_id, vehicle_class_key, effective_from) do update
  set display_name = excluded.display_name,
      source_basis = excluded.source_basis,
      notes = excluded.notes,
      profile_status = excluded.profile_status,
      is_active = true,
      updated_at = now()
  returning id into new_profile_id;

  for component in select * from jsonb_array_elements(coalesce(profile_payload->'components', '[]'::jsonb))
  loop
    insert into public.vehicle_class_internal_cost_components (
      cost_profile_id, component_key, display_name, unit_code, amount, value_status, source_type, source_basis, is_required
    )
    values (
      new_profile_id,
      component->>'component_key',
      coalesce(component->>'display_name', component->>'component_key'),
      coalesce(component->>'unit_code', ''),
      nullif(component->>'amount', '')::numeric,
      coalesce(component->>'value_status', case when nullif(component->>'amount', '') is null then 'not_configured' else 'manual_configured' end),
      coalesce(component->>'source_type', case when nullif(component->>'amount', '') is null then 'requires_time_trucking_input' else 'vehicle_class_specific' end),
      coalesce(component->>'source_basis', 'Manually configured by Time Trucking'),
      coalesce((component->>'is_required')::boolean, true)
    )
    on conflict (cost_profile_id, component_key) do update
    set amount = excluded.amount,
        value_status = excluded.value_status,
        source_type = excluded.source_type,
        source_basis = excluded.source_basis,
        display_name = excluded.display_name,
        unit_code = excluded.unit_code,
        is_required = excluded.is_required,
        updated_at = now();
  end loop;

  return new_profile_id;
end;
$$;

revoke all on function public.ttaq_save_vehicle_class_internal_cost_profile(jsonb) from public;
grant execute on function public.ttaq_save_vehicle_class_internal_cost_profile(jsonb) to authenticated;

comment on table public.vehicle_operating_costs is
  'Legacy generic operating-cost profile preserved for historical compatibility. New internal operating-cost analysis uses vehicle_class_internal_cost_profiles and does not silently fall back to these values for new profitability estimates.';

comment on table public.vehicle_class_internal_cost_profiles is
  'Versioned Time Trucking vehicle-class internal operating-cost profiles. NULL component amounts mean not configured, not confirmed zero.';
