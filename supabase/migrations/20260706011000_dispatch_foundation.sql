create extension if not exists pgcrypto;

alter table public.transport_jobs
  add column if not exists driver_placeholder text,
  add column if not exists truck_placeholder text,
  add column if not exists dispatcher_notes text,
  add column if not exists planned_pickup_time timestamptz,
  add column if not exists planned_delivery_time timestamptz,
  add column if not exists actual_pickup_time timestamptz,
  add column if not exists actual_delivery_time timestamptz;

alter table public.transport_jobs
  alter column job_status set default 'draft';

update public.transport_jobs
set job_status = 'draft'
where job_status = 'pending_assignment';

update public.transport_jobs
set job_status = 'scheduled'
where job_status = 'assigned';

update public.transport_jobs
set job_status = 'active'
where job_status = 'in_progress';

create index if not exists transport_jobs_dispatch_status_idx
on public.transport_jobs(job_status, planned_pickup_time);

create or replace function public.ttaq_update_job_dispatch(
  target_transport_job_id uuid,
  driver_placeholder_value text default null,
  truck_placeholder_value text default null,
  dispatcher_notes_value text default null,
  planned_pickup_time_value timestamptz default null,
  planned_delivery_time_value timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  previous_payload jsonb;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Only approved Time Trucking internal users can update dispatch details.';
  end if;

  select jsonb_build_object(
    'driver_placeholder', driver_placeholder,
    'truck_placeholder', truck_placeholder,
    'dispatcher_notes', dispatcher_notes,
    'planned_pickup_time', planned_pickup_time,
    'planned_delivery_time', planned_delivery_time
  )
    into previous_payload
  from public.transport_jobs
  where id = target_transport_job_id;

  if previous_payload is null then
    raise exception 'Transport job not found: %', target_transport_job_id;
  end if;

  update public.transport_jobs
  set
    driver_placeholder = nullif(driver_placeholder_value, ''),
    truck_placeholder = nullif(truck_placeholder_value, ''),
    dispatcher_notes = nullif(dispatcher_notes_value, ''),
    planned_pickup_time = planned_pickup_time_value,
    planned_delivery_time = planned_delivery_time_value,
    job_status = case
      when job_status = 'draft'
        and (
          nullif(driver_placeholder_value, '') is not null
          or nullif(truck_placeholder_value, '') is not null
          or planned_pickup_time_value is not null
          or planned_delivery_time_value is not null
        )
      then 'scheduled'
      else job_status
    end
  where id = target_transport_job_id;

  insert into public.transport_job_events (
    transport_job_id,
    event_type,
    event_notes,
    event_payload,
    created_by
  )
  values (
    target_transport_job_id,
    'dispatch_updated',
    'Dispatch assignment, planned times, or notes updated.',
    jsonb_build_object(
      'previous', previous_payload,
      'next', jsonb_build_object(
        'driver_placeholder', nullif(driver_placeholder_value, ''),
        'truck_placeholder', nullif(truck_placeholder_value, ''),
        'dispatcher_notes', nullif(dispatcher_notes_value, ''),
        'planned_pickup_time', planned_pickup_time_value,
        'planned_delivery_time', planned_delivery_time_value
      )
    ),
    auth.uid()
  );
end;
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

  if next_status not in ('draft', 'scheduled', 'active', 'completed', 'cancelled') then
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
  set
    job_status = next_status,
    actual_pickup_time = case
      when next_status = 'active' and actual_pickup_time is null then now()
      else actual_pickup_time
    end,
    actual_delivery_time = case
      when next_status in ('completed', 'cancelled') and actual_delivery_time is null then now()
      else actual_delivery_time
    end
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
    'dispatch_status_changed',
    previous_status,
    next_status,
    nullif(status_notes, ''),
    auth.uid()
  );
end;
$$;

drop function if exists public.ttaq_get_internal_job(uuid);

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
  driver_placeholder text,
  truck_placeholder text,
  dispatcher_notes text,
  planned_pickup_time timestamptz,
  planned_delivery_time timestamptz,
  actual_pickup_time timestamptz,
  actual_delivery_time timestamptz,
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
    tj.driver_placeholder,
    tj.truck_placeholder,
    tj.dispatcher_notes,
    tj.planned_pickup_time,
    tj.planned_delivery_time,
    tj.actual_pickup_time,
    tj.actual_delivery_time,
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

drop function if exists public.ttaq_list_internal_jobs();

create or replace function public.ttaq_list_internal_jobs()
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
  driver_placeholder text,
  truck_placeholder text,
  dispatcher_notes text,
  planned_pickup_time timestamptz,
  planned_delivery_time timestamptz,
  actual_pickup_time timestamptz,
  actual_delivery_time timestamptz,
  route_summary jsonb,
  cargo_summary jsonb,
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
    tj.driver_placeholder,
    tj.truck_placeholder,
    tj.dispatcher_notes,
    tj.planned_pickup_time,
    tj.planned_delivery_time,
    tj.actual_pickup_time,
    tj.actual_delivery_time,
    tj.route_summary,
    tj.cargo_summary,
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
