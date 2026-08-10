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
  system_profile_record public.standard_equipment_profiles%rowtype;
  calculation_id uuid;
  total_weight numeric := 0;
  total_volume numeric := 0;
  total_deck_area numeric := 0;
  item_count numeric := 0;
  has_pallets boolean := false;
  target_units integer := 1;
  payload_util numeric := 0;
  volume_util numeric := 0;
  deck_util numeric := 0;
  history_entry jsonb;
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

  update public.vehicle_recommendations
     set system_number_of_trucks = coalesce(system_number_of_trucks, number_of_trucks),
         system_payload_utilization_percent = coalesce(system_payload_utilization_percent, estimated_payload_utilization_percent),
         system_volume_utilization_percent = coalesce(system_volume_utilization_percent, estimated_volume_utilization_percent),
         system_deck_utilization_percent = coalesce(system_deck_utilization_percent, estimated_deck_utilization_percent)
   where id = recommendation_record.id
   returning * into recommendation_record;

  select coalesce(sum(coalesce(
           nullif(substring(coalesce(notes, '') from 'Total shipment weight:\s*([0-9]+(?:\.[0-9]+)?)\s*kg'), '')::numeric,
           coalesce(quantity, 1) * coalesce(weight_kg, 0)
         )), 0),
         coalesce(sum(coalesce(quantity, 1) * coalesce(length_m, 0) * coalesce(width_m, 0) * coalesce(height_m, 0)), 0),
         coalesce(sum(coalesce(quantity, 1) * coalesce(length_m, 0) * coalesce(width_m, 0)), 0),
         coalesce(sum(coalesce(quantity, 1)), 0),
         coalesce(bool_or(coalesce(notes, '') ilike '%Freight type: Pallets%'), false)
    into total_weight, total_volume, total_deck_area, item_count, has_pallets
  from public.quote_items
  where quote_request_id = target_quote_request_id;

  if target_equipment_profile_id is null then
    select * into system_profile_record
    from public.standard_equipment_profiles
    where id = recommendation_record.system_equipment_profile_id
      and is_active;

    if system_profile_record.id is null then
      raise exception 'System equipment profile is not active';
    end if;

    target_units := greatest(
      1,
      ceiling(greatest(
        case when coalesce(system_profile_record.payload_capacity_kg, 0) > 0 then total_weight / system_profile_record.payload_capacity_kg else 1 end,
        case when coalesce(system_profile_record.usable_cube_m3, 0) > 0 then total_volume / system_profile_record.usable_cube_m3 else 1 end,
        case when coalesce(system_profile_record.usable_deck_area_m2, 0) > 0 then total_deck_area / system_profile_record.usable_deck_area_m2 else 1 end,
        case when coalesce(system_profile_record.typical_pallet_capacity, 0) > 0 and has_pallets then item_count / system_profile_record.typical_pallet_capacity else 1 end
      ))::integer
    );
    payload_util := least(100, round((total_weight / nullif(coalesce(system_profile_record.payload_capacity_kg, 0) * target_units, 0)) * 100, 2));
    volume_util := least(100, round((total_volume / nullif(coalesce(system_profile_record.usable_cube_m3, 0) * target_units, 0)) * 100, 2));
    deck_util := least(100, round((total_deck_area / nullif(coalesce(system_profile_record.usable_deck_area_m2, 0) * target_units, 0)) * 100, 2));
    history_entry := jsonb_build_object(
      'action', 'reset_to_system',
      'from_equipment_profile_id', recommendation_record.final_equipment_profile_id,
      'to_equipment_profile_id', recommendation_record.system_equipment_profile_id,
      'from_equipment', coalesce(recommendation_record.override_vehicle_type, recommendation_record.recommended_vehicle_type),
      'to_equipment', system_profile_record.display_name,
      'from_units', recommendation_record.number_of_trucks,
      'to_units', target_units,
      'reason', coalesce(nullif(override_reason_value, ''), 'Reset to system recommendation'),
      'user_id', auth.uid(),
      'timestamp', now()
    );

    update public.vehicle_recommendations
       set final_equipment_profile_id = system_equipment_profile_id,
           override_vehicle_type = null,
           override_trailer_type = null,
           override_reason = null,
           overridden_by = auth.uid(),
           overridden_at = now(),
           reset_to_system_at = now(),
           number_of_trucks = target_units,
           equipment_source = coalesce(system_profile_record.equipment_source_default, 'either'),
           estimated_payload_utilization_percent = coalesce(payload_util, 0),
           estimated_volume_utilization_percent = coalesce(volume_util, 0),
           estimated_deck_utilization_percent = coalesce(deck_util, 0),
           equipment_override_history = coalesce(equipment_override_history, '[]'::jsonb) || jsonb_build_array(history_entry)
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

    target_units := greatest(1, coalesce(unit_count_value, recommendation_record.number_of_trucks, 1));
    payload_util := least(100, round((total_weight / nullif(coalesce(profile_record.payload_capacity_kg, 0) * target_units, 0)) * 100, 2));
    volume_util := least(100, round((total_volume / nullif(coalesce(profile_record.usable_cube_m3, 0) * target_units, 0)) * 100, 2));
    deck_util := least(100, round((total_deck_area / nullif(coalesce(profile_record.usable_deck_area_m2, 0) * target_units, 0)) * 100, 2));
    history_entry := jsonb_build_object(
      'action', 'apply_override',
      'from_equipment_profile_id', recommendation_record.final_equipment_profile_id,
      'to_equipment_profile_id', profile_record.id,
      'from_equipment', coalesce(recommendation_record.override_vehicle_type, recommendation_record.recommended_vehicle_type),
      'to_equipment', profile_record.display_name,
      'from_units', recommendation_record.number_of_trucks,
      'to_units', target_units,
      'equipment_source', case
        when equipment_source_value in ('own_fleet', 'subcontractor', 'either') then equipment_source_value
        else 'either'
      end,
      'reason', override_reason_value,
      'user_id', auth.uid(),
      'timestamp', now()
    );

    update public.vehicle_recommendations
       set final_equipment_profile_id = profile_record.id,
           override_vehicle_type = profile_record.display_name,
           override_trailer_type = profile_record.trailer_body,
           override_reason = override_reason_value,
           overridden_by = auth.uid(),
           overridden_at = now(),
           number_of_trucks = target_units,
           equipment_source = case
             when equipment_source_value in ('own_fleet', 'subcontractor', 'either') then equipment_source_value
             else 'either'
           end,
           estimated_payload_utilization_percent = coalesce(payload_util, 0),
           estimated_volume_utilization_percent = coalesce(volume_util, 0),
           estimated_deck_utilization_percent = coalesce(deck_util, 0),
           equipment_override_history = coalesce(equipment_override_history, '[]'::jsonb) || jsonb_build_array(history_entry)
     where id = recommendation_record.id;
  end if;

  calculation_id := public.ttaq_generate_price(target_quote_request_id, 0, 0);
  return calculation_id;
end;
$$;
