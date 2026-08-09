create extension if not exists pgcrypto;

create table if not exists public.route_estimates (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null unique references public.quote_requests(id) on delete cascade,
  origin_address text,
  destination_address text,
  total_distance_km numeric(14, 2) not null default 0,
  total_duration_hours numeric(14, 2) not null default 0,
  route_notes text,
  provider_name text not null default 'manual_placeholder',
  confidence_level text not null default 'manual',
  provider_response jsonb not null default '{}'::jsonb,
  external_route_id text,
  origin_latitude numeric(10, 7),
  origin_longitude numeric(10, 7),
  destination_latitude numeric(10, 7),
  destination_longitude numeric(10, 7),
  manual_distance_km numeric(14, 2),
  manual_duration_hours numeric(14, 2),
  manual_override_reason text,
  manually_overridden_by uuid references public.internal_users(id),
  manually_overridden_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.route_estimate_stops (
  id uuid primary key default gen_random_uuid(),
  route_estimate_id uuid not null references public.route_estimates(id) on delete cascade,
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  quote_stop_id uuid references public.quote_stops(id) on delete set null,
  stop_order integer not null,
  stop_type text,
  address text not null,
  latitude numeric(10, 7),
  longitude numeric(10, 7),
  geocoded boolean not null default false,
  provider_stop_id text,
  created_at timestamptz not null default now()
);

create table if not exists public.route_provider_logs (
  id uuid primary key default gen_random_uuid(),
  route_estimate_id uuid references public.route_estimates(id) on delete cascade,
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  provider_name text not null,
  request_payload jsonb not null default '{}'::jsonb,
  response_payload jsonb not null default '{}'::jsonb,
  status text not null default 'placeholder',
  error_message text,
  created_at timestamptz not null default now()
);

drop trigger if exists ttaq_route_estimates_touch_updated_at on public.route_estimates;

create trigger ttaq_route_estimates_touch_updated_at
before update on public.route_estimates
for each row execute function public.ttaq_touch_updated_at();

create index if not exists route_estimates_quote_request_id_idx
on public.route_estimates(quote_request_id);

create index if not exists route_estimate_stops_quote_request_id_idx
on public.route_estimate_stops(quote_request_id);

create index if not exists route_estimate_stops_estimate_order_idx
on public.route_estimate_stops(route_estimate_id, stop_order);

create index if not exists route_provider_logs_quote_request_id_idx
on public.route_provider_logs(quote_request_id);

alter table public.route_estimates enable row level security;
alter table public.route_estimate_stops enable row level security;
alter table public.route_provider_logs enable row level security;

create policy "Internal users read route estimates"
on public.route_estimates
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create policy "Owner and manager manage route estimates"
on public.route_estimates
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read route estimate stops"
on public.route_estimate_stops
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create policy "Owner and manager manage route estimate stops"
on public.route_estimate_stops
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read route provider logs"
on public.route_provider_logs
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create policy "Owner and manager manage route provider logs"
on public.route_provider_logs
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create or replace function public.ttaq_generate_route_estimate(
  target_quote_request_id uuid,
  manual_distance_km_value numeric default 0,
  manual_duration_hours_value numeric default 0
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
    manual_distance_km,
    manual_duration_hours
  )
  values (
    target_quote_request_id,
    origin_value,
    destination_value,
    coalesce(manual_distance_km_value, 0),
    coalesce(manual_duration_hours_value, 0),
    'Manual placeholder route estimate. Configure Google Maps or Here Maps provider in a future module.',
    'manual_placeholder',
    'manual',
    coalesce(manual_distance_km_value, 0),
    coalesce(manual_duration_hours_value, 0)
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
    status
  )
  values (
    route_id,
    target_quote_request_id,
    'manual_placeholder',
    jsonb_build_object('source', 'route_intelligence_foundation', 'manual_distance_km', coalesce(manual_distance_km_value, 0), 'manual_duration_hours', coalesce(manual_duration_hours_value, 0)),
    '{}'::jsonb,
    'placeholder'
  );

  return route_id;
end;
$$;

create or replace function public.ttaq_update_route_estimate_manual(
  target_quote_request_id uuid,
  manual_distance_km_value numeric,
  manual_duration_hours_value numeric,
  manual_override_reason_value text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  route_id uuid;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Only Time Trucking owner or manager users can update route estimates.';
  end if;

  select id
    into route_id
  from public.route_estimates
  where quote_request_id = target_quote_request_id;

  if route_id is null then
    route_id := public.ttaq_generate_route_estimate(
      target_quote_request_id,
      coalesce(manual_distance_km_value, 0),
      coalesce(manual_duration_hours_value, 0)
    );
  end if;

  update public.route_estimates
  set
    total_distance_km = coalesce(manual_distance_km_value, 0),
    total_duration_hours = coalesce(manual_duration_hours_value, 0),
    manual_distance_km = coalesce(manual_distance_km_value, 0),
    manual_duration_hours = coalesce(manual_duration_hours_value, 0),
    manual_override_reason = nullif(manual_override_reason_value, ''),
    manually_overridden_by = auth.uid(),
    manually_overridden_at = now(),
    provider_name = 'manual_placeholder',
    confidence_level = 'manual',
    route_notes = coalesce(nullif(manual_override_reason_value, ''), route_notes)
  where id = route_id;

  perform public.ttaq_generate_price(
    target_quote_request_id,
    coalesce(manual_distance_km_value, 0),
    coalesce(manual_duration_hours_value, 0)
  );

  return route_id;
end;
$$;

create or replace function public.ttaq_generate_price_from_vehicle_recommendation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  route_id uuid;
  route_distance numeric;
  route_duration numeric;
begin
  route_id := public.ttaq_generate_route_estimate(new.quote_request_id, 0, 0);

  select total_distance_km, total_duration_hours
    into route_distance, route_duration
  from public.route_estimates
  where id = route_id;

  perform public.ttaq_generate_price(
    new.quote_request_id,
    coalesce(route_distance, 0),
    coalesce(route_duration, 0)
  );

  return new;
end;
$$;
