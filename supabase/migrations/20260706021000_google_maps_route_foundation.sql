create extension if not exists pgcrypto;

alter table public.route_estimates
  add column if not exists google_maps_url text,
  add column if not exists provider_status text not null default 'placeholder',
  add column if not exists provider_error text,
  add column if not exists estimated_at timestamptz;

alter table public.route_estimate_stops
  add column if not exists place_id text,
  add column if not exists formatted_address text;

create or replace function public.ttaq_update_route_estimate_google(
  target_quote_request_id uuid,
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
  origin_value text;
  destination_value text;
  fallback_request public.quote_requests%rowtype;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Only Time Trucking owner or manager users can update Google route estimates.';
  end if;

  select *
    into fallback_request
  from public.quote_requests
  where id = target_quote_request_id;

  if fallback_request.id is null then
    raise exception 'Quote request not found: %', target_quote_request_id;
  end if;

  select qs.address
    into origin_value
  from public.quote_stops qs
  where qs.quote_request_id = target_quote_request_id
  order by qs.stop_order asc, qs.created_at asc
  limit 1;

  select qs.address
    into destination_value
  from public.quote_stops qs
  where qs.quote_request_id = target_quote_request_id
  order by qs.stop_order desc, qs.created_at desc
  limit 1;

  origin_value := coalesce(origin_value, fallback_request.collection_address);
  destination_value := coalesce(destination_value, fallback_request.delivery_address);

  delete from public.route_estimates
  where quote_request_id = target_quote_request_id;

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
    manual_distance_km,
    manual_duration_hours
  )
  values (
    target_quote_request_id,
    origin_value,
    destination_value,
    coalesce(google_distance_km_value, 0),
    coalesce(google_duration_hours_value, 0),
    'Google Maps route estimate. Manual fallback remains available if this estimate needs manager adjustment.',
    'google_maps',
    case when provider_status_value = 'success' then 'google_estimate' else 'fallback_available' end,
    coalesce(provider_response_value, '{}'::jsonb),
    nullif(google_maps_url_value, ''),
    coalesce(provider_status_value, 'success'),
    nullif(provider_error_value, ''),
    now(),
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
    address
  )
  select
    route_id,
    qs.quote_request_id,
    qs.id,
    qs.stop_order,
    qs.stop_type,
    qs.address
  from public.quote_stops qs
  where qs.quote_request_id = target_quote_request_id
  order by qs.stop_order asc, qs.created_at asc;

  if not exists (
    select 1 from public.route_estimate_stops res
    where res.route_estimate_id = route_id
  ) then
    insert into public.route_estimate_stops (
      route_estimate_id,
      quote_request_id,
      stop_order,
      stop_type,
      address
    )
    values
      (route_id, target_quote_request_id, 1, 'collection', origin_value),
      (route_id, target_quote_request_id, 2, 'delivery', destination_value);
  end if;

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
    jsonb_build_object('source', 'quote_review_google_maps', 'api_key_configured', true),
    coalesce(provider_response_value, '{}'::jsonb),
    coalesce(provider_status_value, 'success'),
    nullif(provider_error_value, '')
  );

  perform public.ttaq_generate_price(
    target_quote_request_id,
    coalesce(google_distance_km_value, 0),
    coalesce(google_duration_hours_value, 0)
  );

  return route_id;
end;
$$;
