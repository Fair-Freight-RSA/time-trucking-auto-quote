create or replace function public.ttaq_create_accepted_load_from_quote(
  target_quote_request_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  request_record public.quote_requests%rowtype;
  existing_job_id uuid;
  latest_document public.quote_documents%rowtype;
  route_record public.route_estimates%rowtype;
  recommendation public.vehicle_recommendations%rowtype;
  accepted_load_id uuid;
  load_number_value text;
  public_ref text;
  route_payload jsonb;
  cargo_payload jsonb;
  vehicle_payload jsonb;
begin
  select id
    into existing_job_id
  from public.transport_jobs
  where quote_request_id = target_quote_request_id;

  if existing_job_id is not null then
    return existing_job_id;
  end if;

  select *
    into request_record
  from public.quote_requests
  where id = target_quote_request_id;

  if request_record.id is null then
    raise exception 'Quote request not found: %', target_quote_request_id;
  end if;

  if request_record.status <> 'client_accepted' then
    raise exception 'Only client accepted quotes can become accepted loads.';
  end if;

  select *
    into latest_document
  from public.quote_documents
  where quote_request_id = request_record.id
  order by version_number desc
  limit 1;

  select *
    into route_record
  from public.route_estimates
  where quote_request_id = request_record.id
  order by created_at desc
  limit 1;

  select *
    into recommendation
  from public.vehicle_recommendations
  where quote_request_id = request_record.id
  order by created_at desc
  limit 1;

  public_ref := coalesce(request_record.public_reference, 'TT-' || upper(left(replace(request_record.id::text, '-', ''), 8)));
  load_number_value := 'LOAD-' || public_ref;

  route_payload := jsonb_build_object(
    'origin_address', coalesce(route_record.origin_address, request_record.collection_address),
    'destination_address', coalesce(route_record.destination_address, request_record.delivery_address),
    'total_distance_km', coalesce(route_record.total_distance_km, 0),
    'total_duration_hours', coalesce(route_record.total_duration_hours, 0),
    'provider_name', coalesce(route_record.provider_name, 'manual_or_pending'),
    'route_notes', route_record.route_notes
  );

  select coalesce(jsonb_agg(jsonb_build_object(
    'description', qi.description,
    'cargo_category', qi.cargo_category,
    'quantity', qi.quantity,
    'length_m', qi.length_m,
    'width_m', qi.width_m,
    'height_m', qi.height_m,
    'weight_kg', qi.weight_kg,
    'stackable', qi.stackable,
    'fragile', qi.fragile,
    'dangerous_goods', qi.dangerous_goods,
    'temperature_controlled', qi.temperature_controlled,
    'cargo_value', qi.cargo_value,
    'notes', qi.notes
  ) order by qi.created_at asc), '[]'::jsonb)
    into cargo_payload
  from public.quote_items qi
  where qi.quote_request_id = request_record.id;

  vehicle_payload := jsonb_build_object(
    'recommended_vehicle_type', coalesce(recommendation.recommended_vehicle_type, 'To be confirmed'),
    'recommended_trailer_type', coalesce(recommendation.recommended_trailer_type, 'To be confirmed'),
    'number_of_trucks', coalesce(recommendation.number_of_trucks, 1),
    'abnormal_load', coalesce(recommendation.abnormal_load, false),
    'permit_required', coalesce(recommendation.permit_required, false),
    'escort_recommended', coalesce(recommendation.escort_recommended, false),
    'hazmat_required', coalesce(recommendation.hazmat_required, false),
    'refrigeration_required', coalesce(recommendation.refrigeration_required, false),
    'crane_required', coalesce(recommendation.crane_required, false),
    'forklift_required', coalesce(recommendation.forklift_required, false)
  );

  insert into public.transport_jobs (
    quote_request_id,
    quote_document_id,
    job_number,
    public_reference,
    job_status,
    company_name,
    contact_person,
    email,
    phone,
    collection_date,
    delivery_date,
    route_summary,
    cargo_summary,
    vehicle_summary,
    customer_payload
  )
  values (
    request_record.id,
    latest_document.id,
    load_number_value,
    public_ref,
    'pending_assignment',
    request_record.company_name,
    request_record.contact_person,
    request_record.email,
    request_record.phone,
    request_record.collection_date,
    request_record.delivery_date,
    route_payload,
    cargo_payload,
    vehicle_payload,
    coalesce(latest_document.customer_payload, '{}'::jsonb)
  )
  returning id into accepted_load_id;

  insert into public.transport_job_stops (
    transport_job_id,
    quote_stop_id,
    stop_order,
    stop_type,
    address,
    contact_name,
    contact_phone,
    date_time_window,
    loading_method,
    offloading_method,
    notes
  )
  select
    accepted_load_id,
    qs.id,
    qs.stop_order,
    qs.stop_type,
    qs.address,
    qs.contact_name,
    qs.contact_phone,
    qs.date_time_window,
    qs.loading_method,
    qs.offloading_method,
    qs.notes
  from public.quote_stops qs
  where qs.quote_request_id = request_record.id
  order by qs.stop_order asc, qs.created_at asc;

  if not exists (
    select 1 from public.transport_job_stops where transport_job_id = accepted_load_id
  ) then
    insert into public.transport_job_stops (
      transport_job_id,
      stop_order,
      stop_type,
      address
    )
    values
      (accepted_load_id, 1, 'collection', request_record.collection_address),
      (accepted_load_id, 2, 'delivery', request_record.delivery_address);
  end if;

  if latest_document.id is not null then
    insert into public.transport_job_documents (
      transport_job_id,
      quote_document_id,
      document_type,
      document_name,
      pdf_url,
      pdf_storage_path,
      customer_safe
    )
    values (
      accepted_load_id,
      latest_document.id,
      'quote',
      latest_document.quote_number,
      latest_document.pdf_url,
      latest_document.pdf_storage_path,
      true
    );
  end if;

  insert into public.transport_job_events (
    transport_job_id,
    event_type,
    to_status,
    event_notes
  )
  values (
    accepted_load_id,
    'accepted_load_created_from_quote',
    'pending_assignment',
    'Customer accepted quote; accepted load/order number created.'
  );

  return accepted_load_id;
end;
$$;

alter table public.diesel_price_integrations
  add column if not exists provider_id text,
  add column if not exists previous_price_per_litre numeric(14, 4),
  add column if not exists surcharge_percent_snapshot numeric(10, 4),
  add column if not exists refreshed_at timestamptz,
  add column if not exists manual_override_enabled boolean not null default true;

create or replace function public.ttaq_save_diesel_integration_settings(
  settings_payload jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_id uuid;
  current_price numeric;
  baseline_price numeric;
  previous_price numeric;
  surcharge_percent numeric;
  manual_enabled boolean;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules') then
    raise exception 'Only approved Time Trucking pricing users can update diesel settings.';
  end if;

  select id
    into profile_id
  from public.pricing_profiles
  where is_active = true
  order by created_at desc
  limit 1;

  if profile_id is null then
    raise exception 'No active pricing profile exists.';
  end if;

  current_price := coalesce(
    nullif(settings_payload->>'diesel_admin_override_price_per_litre', '')::numeric,
    nullif(settings_payload->>'fuel_price_per_litre', '')::numeric,
    0
  );
  baseline_price := nullif(settings_payload->>'diesel_base_price_per_litre', '')::numeric;
  previous_price := nullif(settings_payload->>'diesel_previous_price_per_litre', '')::numeric;
  manual_enabled := coalesce(settings_payload->>'diesel_manual_override_enabled', 'true') in ('true', '1', 'on', 'yes');
  surcharge_percent := case
    when baseline_price is not null and baseline_price > 0 and current_price > baseline_price
      then round(((current_price - baseline_price) / baseline_price) * 100, 4)
    else 0
  end;

  insert into public.diesel_price_integrations (
    pricing_profile_id,
    provider_name,
    provider_status,
    provider_id,
    provider_price_per_litre,
    admin_override_price_per_litre,
    previous_price_per_litre,
    surcharge_percent_snapshot,
    effective_from,
    refreshed_at,
    manual_override_enabled,
    provider_response
  )
  values (
    profile_id,
    'manual_admin_override',
    'manual_fallback',
    nullif(settings_payload->>'diesel_provider_id', ''),
    null,
    current_price,
    previous_price,
    surcharge_percent,
    coalesce(nullif(settings_payload->>'diesel_effective_from', '')::date, current_date),
    coalesce(nullif(settings_payload->>'diesel_refreshed_at', '')::timestamptz, now()),
    manual_enabled,
    jsonb_build_object(
      'source', 'pricing_settings_page',
      'live_provider_configured', false,
      'baseline_price_per_litre', baseline_price,
      'fuel_surcharge_enabled', coalesce(settings_payload->>'fuel_surcharge_enabled', 'true')
    )
  );
end;
$$;

create or replace function public.ttaq_record_public_quote_response(
  raw_response_token text,
  public_reference_value text,
  decision_status public.ttaq_quote_status
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_id uuid;
  old_status public.ttaq_quote_status;
  accepted_load_id uuid;
begin
  if decision_status not in ('client_accepted', 'client_declined') then
    raise exception 'Invalid quote response';
  end if;

  select id, status
    into target_id, old_status
  from public.quote_requests
  where status in ('sent_to_client', 'client_accepted')
    and (
      response_token_hash = public.ttaq_hash_token(raw_response_token)
      or (
        public_reference_value is not null
        and public_reference = public_reference_value
      )
    )
  limit 1;

  if target_id is null then
    raise exception 'Quote not found or not open for response';
  end if;

  if old_status = 'client_accepted' and decision_status = 'client_accepted' then
    accepted_load_id := public.ttaq_create_accepted_load_from_quote(target_id);

    insert into public.notifications (quote_request_id, recipient_email, notification_type, payload)
    values (
      target_id,
      'admin@timetrucking.co.za',
      'quote_response_placeholder',
      jsonb_build_object('decision', decision_status, 'accepted_load_id', accepted_load_id, 'idempotent_repeat', true)
    );

    return;
  end if;

  if old_status = 'client_accepted' and decision_status = 'client_declined' then
    raise exception 'Accepted quotes cannot be declined afterward';
  end if;

  update public.quote_requests
     set status = decision_status,
         client_responded_at = now()
   where id = target_id;

  if decision_status = 'client_accepted' then
    accepted_load_id := public.ttaq_create_accepted_load_from_quote(target_id);
  end if;

  insert into public.quote_status_events (quote_request_id, from_status, to_status, note)
  values (
    target_id,
    old_status,
    decision_status,
    case
      when decision_status = 'client_accepted' then 'Public quote accepted; accepted load created'
      else 'Public quote declined; manager review required'
    end
  );

  insert into public.notifications (quote_request_id, recipient_email, notification_type, payload)
  values (
    target_id,
    'admin@timetrucking.co.za',
    'quote_response_placeholder',
    jsonb_build_object('decision', decision_status, 'accepted_load_id', accepted_load_id)
  );
end;
$$;

create or replace function public.ttaq_archive_quote_request(
  target_quote_request_id uuid,
  archive_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  old_status public.ttaq_quote_status;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Only approved Time Trucking internal users can archive quote requests.';
  end if;

  select status
    into old_status
  from public.quote_requests
  where id = target_quote_request_id;

  if old_status is null then
    raise exception 'Quote request not found: %', target_quote_request_id;
  end if;

  if old_status in ('client_accepted', 'converted_to_load') then
    raise exception 'Accepted quotes cannot be archived from quote review.';
  end if;

  update public.quote_requests
     set status = 'expired',
         admin_notes = concat_ws(E'\n', nullif(admin_notes, ''), nullif(archive_note, ''))
   where id = target_quote_request_id;

  insert into public.quote_status_events (quote_request_id, from_status, to_status, note, created_by)
  values (target_quote_request_id, old_status, 'expired', coalesce(nullif(archive_note, ''), 'Archived from quote review'), auth.uid());
end;
$$;
