create or replace function public.ttaq_apply_google_route_automation(
  target_quote_request_id uuid,
  raw_response_token text,
  public_reference_value text,
  google_distance_km_value numeric,
  google_duration_hours_value numeric,
  google_maps_url_value text default null,
  provider_response_value jsonb default '{}'::jsonb,
  provider_status_value text default 'success',
  provider_error_value text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  route_id uuid;
  request_record public.quote_requests%rowtype;
  origin_value text;
  destination_value text;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Only the backend route automation service can apply route estimates.';
  end if;

  if raw_response_token is null or length(raw_response_token) = 0 then
    raise exception 'Missing quote response token.';
  end if;

  select *
    into request_record
  from public.quote_requests
  where id = target_quote_request_id
    and public_reference = public_reference_value
    and response_token_hash = public.ttaq_hash_token(raw_response_token)
  limit 1;

  if request_record.id is null then
    raise exception 'Quote request could not be verified for route automation.';
  end if;

  select coalesce(qs.formatted_address, qs.address)
    into origin_value
  from public.quote_stops qs
  where qs.quote_request_id = target_quote_request_id
  order by qs.stop_order asc, qs.created_at asc
  limit 1;

  select coalesce(qs.formatted_address, qs.address)
    into destination_value
  from public.quote_stops qs
  where qs.quote_request_id = target_quote_request_id
  order by qs.stop_order desc, qs.created_at desc
  limit 1;

  origin_value := coalesce(origin_value, request_record.collection_address);
  destination_value := coalesce(destination_value, request_record.delivery_address);

  update public.quote_stops qs
     set latitude = nullif(stop_json.value->>'latitude', '')::numeric,
         longitude = nullif(stop_json.value->>'longitude', '')::numeric,
         place_id = nullif(stop_json.value->>'place_id', ''),
         formatted_address = nullif(stop_json.value->>'formatted_address', '')
    from jsonb_array_elements(coalesce(provider_response_value->'stops', '[]'::jsonb)) stop_json(value)
   where qs.quote_request_id = target_quote_request_id
     and qs.stop_order = coalesce(nullif(stop_json.value->>'stop_order', '')::integer, qs.stop_order);

  insert into public.route_estimates (
    quote_request_id,
    origin_address,
    destination_address,
    total_distance_km,
    total_duration_hours,
    route_notes,
    provider_name,
    confidence_level,
    provider_response,
    google_maps_url,
    provider_status,
    provider_error,
    estimated_at,
    encoded_polyline,
    toll_status,
    route_risk_status,
    manual_distance_km,
    manual_duration_hours
  )
  values (
    target_quote_request_id,
    origin_value,
    destination_value,
    case when provider_status_value = 'success' then coalesce(google_distance_km_value, 0) else 0 end,
    case when provider_status_value = 'success' then coalesce(google_duration_hours_value, 0) else 0 end,
    case
      when provider_status_value = 'success' then 'Google Routes route estimate generated automatically after public RFQ submission.'
      else 'Google Routes automation failed. Manual route review is required before relying on pricing.'
    end,
    'google_maps',
    case when provider_status_value = 'success' then 'google_estimate' else 'manual_review_required' end,
    coalesce(provider_response_value, '{}'::jsonb),
    nullif(google_maps_url_value, ''),
    coalesce(provider_status_value, 'failed'),
    nullif(provider_error_value, ''),
    now(),
    nullif(provider_response_value->>'overview_polyline', ''),
    coalesce(nullif(provider_response_value->>'toll_status', ''), 'unavailable'),
    coalesce(nullif(provider_response_value->>'route_risk_status', ''), 'default_or_manual'),
    null,
    null
  )
  returning id into route_id;

  insert into public.route_estimate_stops (
    route_estimate_id,
    quote_request_id,
    quote_stop_id,
    stop_order,
    stop_type,
    address,
    latitude,
    longitude,
    geocoded,
    provider_stop_id,
    place_id,
    formatted_address
  )
  select
    route_id,
    qs.quote_request_id,
    qs.id,
    qs.stop_order,
    qs.stop_type,
    qs.address,
    qs.latitude,
    qs.longitude,
    qs.latitude is not null and qs.longitude is not null,
    qs.place_id,
    qs.place_id,
    qs.formatted_address
  from public.quote_stops qs
  where qs.quote_request_id = target_quote_request_id
  order by qs.stop_order asc, qs.created_at asc;

  insert into public.route_provider_logs (
    route_estimate_id,
    quote_request_id,
    provider_name,
    request_payload,
    response_payload,
    status,
    error_message
  )
  values (
    route_id,
    target_quote_request_id,
    'google_maps',
    jsonb_build_object('source', 'auto_route_public_rfq', 'api', 'routes_api'),
    coalesce(provider_response_value, '{}'::jsonb),
    coalesce(provider_status_value, 'failed'),
    nullif(provider_error_value, '')
  );

  if provider_status_value = 'success' and coalesce(google_distance_km_value, 0) > 0 then
    perform public.ttaq_generate_price(
      target_quote_request_id,
      google_distance_km_value,
      coalesce(google_duration_hours_value, 0)
    );
  end if;

  return route_id;
end;
$$;

revoke all on function public.ttaq_apply_google_route_automation(uuid, text, text, numeric, numeric, text, jsonb, text, text) from public;
revoke all on function public.ttaq_apply_google_route_automation(uuid, text, text, numeric, numeric, text, jsonb, text, text) from anon;
revoke all on function public.ttaq_apply_google_route_automation(uuid, text, text, numeric, numeric, text, jsonb, text, text) from authenticated;
grant execute on function public.ttaq_apply_google_route_automation(uuid, text, text, numeric, numeric, text, jsonb, text, text) to service_role;
