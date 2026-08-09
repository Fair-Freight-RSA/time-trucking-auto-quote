create extension if not exists pgcrypto;

alter table public.quote_stops
  add column if not exists latitude numeric,
  add column if not exists longitude numeric,
  add column if not exists place_id text,
  add column if not exists formatted_address text;

alter table public.route_estimates
  add column if not exists encoded_polyline text,
  add column if not exists toll_status text not null default 'unavailable',
  add column if not exists route_risk_status text not null default 'default_or_manual';

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

  origin_value := coalesce(origin_value, fallback_request.collection_address);
  destination_value := coalesce(destination_value, fallback_request.delivery_address);

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

create or replace function public.ttaq_add_auto_quote_check_constraint_if_missing(
  target_table regclass,
  constraint_name text,
  constraint_sql text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = constraint_name
      and conrelid = target_table
  ) then
    execute format('alter table %s add constraint %I check (%s) not valid', target_table, constraint_name, constraint_sql);
  end if;
end;
$$;

select public.ttaq_add_auto_quote_check_constraint_if_missing(
  'public.route_estimates',
  'route_estimates_non_negative_distance_check',
  'total_distance_km >= 0 and total_duration_hours >= 0 and coalesce(manual_distance_km, 0) >= 0 and coalesce(manual_duration_hours, 0) >= 0'
);

select public.ttaq_add_auto_quote_check_constraint_if_missing(
  'public.route_estimate_stops',
  'route_estimate_stops_order_positive_check',
  'stop_order > 0'
);

select public.ttaq_add_auto_quote_check_constraint_if_missing(
  'public.quote_stops',
  'quote_stops_order_positive_check',
  'stop_order > 0'
);

select public.ttaq_add_auto_quote_check_constraint_if_missing(
  'public.transport_job_stops',
  'transport_job_stops_order_positive_check',
  'stop_order > 0'
);

select public.ttaq_add_auto_quote_check_constraint_if_missing(
  'public.quote_documents',
  'quote_documents_pdf_path_safe_check',
  'pdf_storage_path is null or (pdf_storage_path !~ ''(^/|\\.\\.)'')'
);

create index if not exists quote_requests_status_created_idx
on public.quote_requests(status, created_at desc);

create index if not exists quote_stops_request_order_idx
on public.quote_stops(quote_request_id, stop_order);

create index if not exists route_estimate_stops_route_order_idx
on public.route_estimate_stops(route_estimate_id, stop_order);

drop function public.ttaq_add_auto_quote_check_constraint_if_missing(regclass, text, text);
