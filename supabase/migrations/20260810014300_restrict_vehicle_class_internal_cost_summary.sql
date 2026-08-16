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
  with permitted as (
    select public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
        or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
        or public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules') as allowed
  ),
  current_profiles as (
    select distinct on (profile.vehicle_class_key)
           profile.*
    from public.vehicle_class_internal_cost_profiles profile
    cross join permitted
    where permitted.allowed
      and profile.pricing_profile_id = public.ttaq_active_pricing_profile()
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

revoke all on function public.ttaq_vehicle_class_internal_cost_profile_summary() from public;
revoke all on function public.ttaq_vehicle_class_internal_cost_profile_summary() from anon;
grant execute on function public.ttaq_vehicle_class_internal_cost_profile_summary() to authenticated;

revoke all on function public.ttaq_save_vehicle_class_internal_cost_profile(jsonb) from public;
revoke all on function public.ttaq_save_vehicle_class_internal_cost_profile(jsonb) from anon;
grant execute on function public.ttaq_save_vehicle_class_internal_cost_profile(jsonb) to authenticated;
