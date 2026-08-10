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
  volume_capacity_review_value boolean := false;
  abnormal_load_value boolean := false;
  permit_required_value boolean := false;
  escort_recommended_value boolean := false;
  crane_required_value boolean := false;
  forklift_required_value boolean := false;
  manager_review_value boolean := false;
  vehicle_type text := 'Dedicated truck';
  trailer_type text := 'Superlink / tautliner review';
  trucks integer := 1;
  payload_capacity numeric := 0;
  volume_capacity numeric := 0;
  max_configured_payload numeric := 0;
  max_configured_volume numeric := 0;
  payload_util numeric := 0;
  volume_util numeric := 0;
  notes text;
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
    total_weight,
    total_volume,
    total_deck_area,
    max_length,
    max_width,
    max_height,
    max_item_weight,
    item_count,
    total_value,
    has_dangerous,
    has_temperature,
    has_fragile,
    has_machinery,
    has_pallets,
    missing_dimensions_value
  from public.quote_items qi
  where qi.quote_request_id = target_quote_request_id;

  select coalesce(max(max_weight_kg), 0), coalesce(max(max_volume_m3), 0)
    into max_configured_payload, max_configured_volume
  from (
    select max_weight_kg, max_volume_m3 from public.vehicle_types where is_active
    union all
    select max_weight_kg, max_volume_m3 from public.trailer_types where is_active
  ) configured_capacity;

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
  payload_capacity_review_value := max_configured_payload > 0 and max_item_weight > max_configured_payload;
  volume_capacity_review_value := max_configured_volume > 0 and total_volume > max_configured_volume;
  abnormal_load_value := dimensionally_abnormal_value;
  permit_required_value := dimensionally_abnormal_value;
  escort_recommended_value := max_width > 3.5 or max_length > 22;
  crane_required_value := has_crane_answer or (has_machinery and total_weight > 8000);
  forklift_required_value := has_forklift_text or (not has_machinery and total_weight > 1000);

  if dimensionally_abnormal_value then
    vehicle_type := 'Heavy haulage truck';
    trailer_type := 'Lowbed';
    payload_capacity := greatest(max_configured_payload, 1);
    volume_capacity := greatest(max_configured_volume, 1);
  elsif has_temperature then
    vehicle_type := 'Dedicated truck';
    trailer_type := 'Superlink / tautliner review';
    payload_capacity := greatest(max_configured_payload, 1);
    volume_capacity := greatest(max_configured_volume, 1);
  elsif has_dangerous then
    vehicle_type := 'Dedicated truck';
    trailer_type := 'Superlink / tautliner review';
    payload_capacity := greatest(max_configured_payload, 1);
    volume_capacity := greatest(max_configured_volume, 1);
  elsif total_weight <= 1000 and total_volume <= 6 then
    vehicle_type := '1-ton bakkie / panel van';
    trailer_type := 'Closed body';
    payload_capacity := 1000;
    volume_capacity := 6;
  elsif total_weight <= 4000 and total_volume <= 22 then
    vehicle_type := '4-ton truck';
    trailer_type := 'Curtain side body';
    payload_capacity := 4000;
    volume_capacity := 22;
  elsif total_weight <= 8000 and total_volume <= 45 then
    vehicle_type := '8-ton truck';
    trailer_type := 'Tautliner';
    payload_capacity := 8000;
    volume_capacity := 45;
  elsif total_weight <= 34000 and total_volume <= 90 then
    vehicle_type := 'Dedicated truck';
    trailer_type := 'Tautliner';
    payload_capacity := 34000;
    volume_capacity := 90;
  else
    vehicle_type := 'Dedicated truck';
    trailer_type := 'Superlink / tautliner review';
    payload_capacity := greatest(max_configured_payload, 1);
    volume_capacity := greatest(max_configured_volume, 1);
  end if;

  trucks := greatest(
    1,
    ceiling(greatest(
      case when payload_capacity > 0 then total_weight / payload_capacity else 1 end,
      case when volume_capacity > 0 then total_volume / volume_capacity else 1 end
    ))::integer
  );

  payload_util := least(100, round((total_weight / nullif(payload_capacity * trucks, 0)) * 100, 2));
  volume_util := least(100, round((total_volume / nullif(volume_capacity * trucks, 0)) * 100, 2));

  manager_review_value :=
    missing_dimensions_value
    or dimensionally_abnormal_value
    or payload_capacity_review_value
    or volume_capacity_review_value
    or permit_required_value
    or escort_recommended_value
    or has_dangerous
    or has_temperature
    or crane_required_value
    or total_value >= 500000
    or has_fragile;

  notes := concat_ws(
    ' ',
    'Vehicle Intelligence summary:',
    item_count || ' item(s).',
    'Total weight ' || total_weight || ' kg.',
    'Total volume ' || round(total_volume, 2) || ' m3.',
    'Deck footprint ' || round(total_deck_area, 2) || ' m2.',
    'Max item ' || max_length || 'm L x ' || max_width || 'm W x ' || max_height || 'm H.',
    case when has_pallets then 'Palletised freight detected from RFQ notes.' else null end,
    case when missing_dimensions_value then 'Dimensions required before relying on the recommendation.' else null end,
    case when dimensionally_abnormal_value then 'Abnormal dimension review required.' else 'No abnormal dimensions detected by the current configured rule.' end,
    case when payload_capacity_review_value then 'Single-item payload exceeds configured normal capacity; manager review required.' else null end,
    case when volume_capacity_review_value then 'Total cube exceeds configured normal capacity; manager review required.' else null end,
    case when has_dangerous then 'Dangerous goods present.' else null end,
    case when has_temperature then 'Temperature-controlled cargo present.' else null end,
    case when crane_required_value then 'Crane requirement flagged.' else null end,
    case when total_value >= 500000 then 'High-value cargo manager review recommended.' else null end,
    trucks || ' truck(s) based on configured payload and cube capacity.'
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
    recommendation_notes
  )
  values (
    target_quote_request_id,
    vehicle_type,
    trailer_type,
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
    notes
  )
  returning id into recommendation_id;

  insert into public.transport_requirement_flags (quote_request_id, vehicle_recommendation_id, flag_key, flag_label, severity, flag_notes)
  select target_quote_request_id, recommendation_id, flag_key, flag_label, severity, flag_notes
  from (
    values
      ('dimensions_required', 'Dimensions required', 'warning', 'Palletised or machinery freight requires length, width, and height before relying on the recommendation.', missing_dimensions_value),
      ('payload_capacity_review', 'Payload capacity review', 'warning', 'Single-item payload exceeds configured normal capacity; manager review required.', payload_capacity_review_value),
      ('volume_capacity_review', 'Volume capacity review', 'warning', 'Total cube exceeds configured normal capacity; manager review required.', volume_capacity_review_value),
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
