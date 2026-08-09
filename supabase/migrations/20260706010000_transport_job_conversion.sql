create extension if not exists pgcrypto;

create table if not exists public.transport_jobs (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null unique references public.quote_requests(id) on delete restrict,
  quote_document_id uuid references public.quote_documents(id) on delete set null,
  job_number text not null unique,
  public_reference text not null,
  job_status text not null default 'pending_assignment',
  company_name text not null,
  contact_person text not null,
  email text not null,
  phone text,
  collection_date date,
  delivery_date date,
  route_summary jsonb not null default '{}'::jsonb,
  cargo_summary jsonb not null default '[]'::jsonb,
  vehicle_summary jsonb not null default '{}'::jsonb,
  customer_payload jsonb not null default '{}'::jsonb,
  created_by uuid references public.internal_users(id),
  assigned_internal_user_id uuid references public.internal_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.transport_job_stops (
  id uuid primary key default gen_random_uuid(),
  transport_job_id uuid not null references public.transport_jobs(id) on delete cascade,
  quote_stop_id uuid references public.quote_stops(id) on delete set null,
  stop_order integer not null,
  stop_type text not null,
  address text not null,
  contact_name text,
  contact_phone text,
  date_time_window text,
  loading_method text,
  offloading_method text,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists public.transport_job_events (
  id uuid primary key default gen_random_uuid(),
  transport_job_id uuid not null references public.transport_jobs(id) on delete cascade,
  event_type text not null,
  from_status text,
  to_status text,
  event_notes text,
  event_payload jsonb not null default '{}'::jsonb,
  created_by uuid references public.internal_users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.transport_job_documents (
  id uuid primary key default gen_random_uuid(),
  transport_job_id uuid not null references public.transport_jobs(id) on delete cascade,
  quote_document_id uuid references public.quote_documents(id) on delete set null,
  document_type text not null default 'quote',
  document_name text not null,
  pdf_url text,
  pdf_storage_path text,
  customer_safe boolean not null default true,
  created_at timestamptz not null default now()
);

drop trigger if exists ttaq_transport_jobs_touch_updated_at on public.transport_jobs;
create trigger ttaq_transport_jobs_touch_updated_at
before update on public.transport_jobs
for each row execute function public.ttaq_touch_updated_at();

create index if not exists transport_jobs_quote_request_id_idx
on public.transport_jobs(quote_request_id);

create index if not exists transport_jobs_job_status_idx
on public.transport_jobs(job_status);

create index if not exists transport_job_stops_job_order_idx
on public.transport_job_stops(transport_job_id, stop_order);

create index if not exists transport_job_events_job_created_idx
on public.transport_job_events(transport_job_id, created_at desc);

create index if not exists transport_job_documents_job_idx
on public.transport_job_documents(transport_job_id);

alter table public.transport_jobs enable row level security;
alter table public.transport_job_stops enable row level security;
alter table public.transport_job_events enable row level security;
alter table public.transport_job_documents enable row level security;

create policy "Internal users read transport jobs"
on public.transport_jobs
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create policy "Owner and manager manage transport jobs"
on public.transport_jobs
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read transport job stops"
on public.transport_job_stops
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create policy "Owner and manager manage transport job stops"
on public.transport_job_stops
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read transport job events"
on public.transport_job_events
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create policy "Owner and manager manage transport job events"
on public.transport_job_events
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read transport job documents"
on public.transport_job_documents
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create policy "Owner and manager manage transport job documents"
on public.transport_job_documents
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create or replace function public.ttaq_convert_quote_to_job(
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
  job_id uuid;
  job_number_value text;
  public_ref text;
  route_payload jsonb;
  cargo_payload jsonb;
  vehicle_payload jsonb;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Only approved Time Trucking internal users can convert accepted quotes to jobs.';
  end if;

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
    raise exception 'Only client accepted quotes can be converted to transport jobs.';
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
  job_number_value := 'JOB-' || public_ref;

  route_payload := jsonb_build_object(
    'origin_address', coalesce(route_record.origin_address, request_record.collection_address),
    'destination_address', coalesce(route_record.destination_address, request_record.delivery_address),
    'total_distance_km', coalesce(route_record.total_distance_km, 0),
    'total_duration_hours', coalesce(route_record.total_duration_hours, 0),
    'provider_name', coalesce(route_record.provider_name, 'manual_placeholder'),
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
    company_name,
    contact_person,
    email,
    phone,
    collection_date,
    delivery_date,
    route_summary,
    cargo_summary,
    vehicle_summary,
    customer_payload,
    created_by
  )
  values (
    request_record.id,
    latest_document.id,
    job_number_value,
    public_ref,
    request_record.company_name,
    request_record.contact_person,
    request_record.email,
    request_record.phone,
    request_record.collection_date,
    request_record.delivery_date,
    route_payload,
    cargo_payload,
    vehicle_payload,
    coalesce(latest_document.customer_payload, '{}'::jsonb),
    auth.uid()
  )
  returning id into job_id;

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
    job_id,
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
    select 1 from public.transport_job_stops where transport_job_id = job_id
  ) then
    insert into public.transport_job_stops (
      transport_job_id,
      stop_order,
      stop_type,
      address
    )
    values
      (job_id, 1, 'collection', request_record.collection_address),
      (job_id, 2, 'delivery', request_record.delivery_address);
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
      job_id,
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
    event_notes,
    created_by
  )
  values (
    job_id,
    'job_created_from_quote',
    'pending_assignment',
    'Accepted quote converted to transport job.',
    auth.uid()
  );

  update public.quote_requests
  set status = 'converted_to_load'
  where id = request_record.id;

  insert into public.quote_status_events (
    quote_request_id,
    from_status,
    to_status,
    note,
    created_by
  )
  values (
    request_record.id,
    'client_accepted',
    'converted_to_load',
    'Accepted quote converted to transport job.',
    auth.uid()
  );

  return job_id;
end;
$$;

create or replace function public.ttaq_get_internal_job(
  target_transport_job_id uuid
)
returns table (
  id uuid,
  quote_request_id uuid,
  quote_document_id uuid,
  job_number text,
  public_reference text,
  job_status text,
  company_name text,
  contact_person text,
  email text,
  phone text,
  collection_date date,
  delivery_date date,
  route_summary jsonb,
  cargo_summary jsonb,
  vehicle_summary jsonb,
  customer_payload jsonb,
  stops jsonb,
  events jsonb,
  documents jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    tj.id,
    tj.quote_request_id,
    tj.quote_document_id,
    tj.job_number,
    tj.public_reference,
    tj.job_status,
    tj.company_name,
    tj.contact_person,
    tj.email,
    tj.phone,
    tj.collection_date,
    tj.delivery_date,
    tj.route_summary,
    tj.cargo_summary,
    tj.vehicle_summary,
    tj.customer_payload,
    coalesce((
      select jsonb_agg(to_jsonb(tjs) order by tjs.stop_order asc)
      from public.transport_job_stops tjs
      where tjs.transport_job_id = tj.id
    ), '[]'::jsonb) as stops,
    coalesce((
      select jsonb_agg(to_jsonb(tje) order by tje.created_at desc)
      from public.transport_job_events tje
      where tje.transport_job_id = tj.id
    ), '[]'::jsonb) as events,
    coalesce((
      select jsonb_agg(to_jsonb(tjd) order by tjd.created_at desc)
      from public.transport_job_documents tjd
      where tjd.transport_job_id = tj.id
    ), '[]'::jsonb) as documents,
    tj.created_at,
    tj.updated_at
  from public.transport_jobs tj
  where tj.id = target_transport_job_id
    and (
      public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
      or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
    );
$$;

create or replace function public.ttaq_list_internal_jobs()
returns table (
  id uuid,
  quote_request_id uuid,
  job_number text,
  public_reference text,
  job_status text,
  company_name text,
  contact_person text,
  collection_date date,
  delivery_date date,
  route_summary jsonb,
  vehicle_summary jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    tj.id,
    tj.quote_request_id,
    tj.job_number,
    tj.public_reference,
    tj.job_status,
    tj.company_name,
    tj.contact_person,
    tj.collection_date,
    tj.delivery_date,
    tj.route_summary,
    tj.vehicle_summary,
    tj.created_at,
    tj.updated_at
  from public.transport_jobs tj
  where (
    public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
    or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
  )
  order by tj.created_at desc;
$$;

create or replace function public.ttaq_update_job_status(
  target_transport_job_id uuid,
  next_status text,
  status_notes text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_status text;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Only approved Time Trucking internal users can update job status.';
  end if;

  if next_status not in ('pending_assignment', 'assigned', 'in_progress', 'completed', 'cancelled') then
    raise exception 'Unsupported job status: %', next_status;
  end if;

  select job_status
    into previous_status
  from public.transport_jobs
  where id = target_transport_job_id;

  if previous_status is null then
    raise exception 'Transport job not found: %', target_transport_job_id;
  end if;

  update public.transport_jobs
  set job_status = next_status
  where id = target_transport_job_id;

  insert into public.transport_job_events (
    transport_job_id,
    event_type,
    from_status,
    to_status,
    event_notes,
    created_by
  )
  values (
    target_transport_job_id,
    'job_status_changed',
    previous_status,
    next_status,
    nullif(status_notes, ''),
    auth.uid()
  );
end;
$$;
