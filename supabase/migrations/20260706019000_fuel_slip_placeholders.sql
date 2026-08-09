create extension if not exists pgcrypto;

create table if not exists public.fuel_slips (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.transport_jobs(id) on delete cascade,
  driver_name text,
  driver_placeholder text,
  truck_placeholder text,
  slip_date date not null default current_date,
  fuel_station text,
  litres numeric(12, 3) not null default 0,
  amount numeric(14, 2) not null default 0,
  vat_amount numeric(14, 2) not null default 0,
  odometer numeric(14, 1),
  notes text,
  document_url text,
  storage_path text,
  status text not null default 'placeholder',
  created_by uuid references public.internal_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fuel_slips_status_check check (status in ('placeholder', 'submitted', 'reviewed', 'rejected', 'archived')),
  constraint fuel_slips_litres_check check (litres >= 0),
  constraint fuel_slips_amount_check check (amount >= 0),
  constraint fuel_slips_vat_amount_check check (vat_amount >= 0)
);

create index if not exists fuel_slips_job_id_idx on public.fuel_slips(job_id);
create index if not exists fuel_slips_slip_date_idx on public.fuel_slips(slip_date desc);
create index if not exists fuel_slips_status_idx on public.fuel_slips(status);

drop trigger if exists ttaq_fuel_slips_touch_updated_at on public.fuel_slips;
create trigger ttaq_fuel_slips_touch_updated_at
before update on public.fuel_slips
for each row execute function public.ttaq_touch_updated_at();

alter table public.fuel_slips enable row level security;

drop policy if exists "Internal users read fuel slips" on public.fuel_slips;
create policy "Internal users read fuel slips"
on public.fuel_slips
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

drop policy if exists "Internal users manage fuel slips" on public.fuel_slips;
create policy "Internal users manage fuel slips"
on public.fuel_slips
for all
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
)
with check (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create or replace function public.ttaq_upload_fuel_slip_placeholder(
  target_transport_job_id uuid,
  driver_name_value text default null,
  driver_placeholder_value text default null,
  truck_placeholder_value text default null,
  slip_date_value date default current_date,
  fuel_station_value text default null,
  litres_value numeric default 0,
  amount_value numeric default 0,
  vat_amount_value numeric default 0,
  odometer_value numeric default null,
  notes_value text default null,
  document_url_value text default null,
  storage_path_value text default null,
  status_value text default 'placeholder'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  job_record public.transport_jobs%rowtype;
  created_fuel_slip_id uuid;
begin
  if not (
    public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
    or public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  ) then
    raise exception 'Only approved Time Trucking internal users can record fuel slips.';
  end if;

  if status_value not in ('placeholder', 'submitted', 'reviewed', 'rejected', 'archived') then
    raise exception 'Unsupported fuel slip status: %', status_value;
  end if;

  select *
    into job_record
  from public.transport_jobs
  where id = target_transport_job_id;

  if job_record.id is null then
    raise exception 'Transport job not found: %', target_transport_job_id;
  end if;

  insert into public.fuel_slips (
    job_id,
    driver_name,
    driver_placeholder,
    truck_placeholder,
    slip_date,
    fuel_station,
    litres,
    amount,
    vat_amount,
    odometer,
    notes,
    document_url,
    storage_path,
    status,
    created_by
  )
  values (
    target_transport_job_id,
    nullif(driver_name_value, ''),
    coalesce(nullif(driver_placeholder_value, ''), job_record.driver_placeholder),
    coalesce(nullif(truck_placeholder_value, ''), job_record.truck_placeholder),
    coalesce(slip_date_value, current_date),
    nullif(fuel_station_value, ''),
    greatest(coalesce(litres_value, 0), 0),
    greatest(coalesce(amount_value, 0), 0),
    greatest(coalesce(vat_amount_value, 0), 0),
    odometer_value,
    nullif(notes_value, ''),
    nullif(document_url_value, ''),
    nullif(storage_path_value, ''),
    status_value,
    auth.uid()
  )
  returning id into created_fuel_slip_id;

  insert into public.transport_job_events (
    transport_job_id,
    event_type,
    event_notes,
    event_payload,
    created_by
  )
  values (
    target_transport_job_id,
    'fuel_slip_placeholder_uploaded',
    coalesce(nullif(notes_value, ''), 'Fuel slip placeholder recorded.'),
    jsonb_build_object(
      'fuel_slip_id', created_fuel_slip_id,
      'fuel_station', nullif(fuel_station_value, ''),
      'litres', greatest(coalesce(litres_value, 0), 0),
      'amount', greatest(coalesce(amount_value, 0), 0),
      'vat_amount', greatest(coalesce(vat_amount_value, 0), 0),
      'status', status_value
    ),
    auth.uid()
  );

  return created_fuel_slip_id;
end;
$$;

create or replace function public.ttaq_list_internal_fuel_slips()
returns table (
  id uuid,
  job_id uuid,
  job_number text,
  public_reference text,
  job_status text,
  driver_name text,
  driver_placeholder text,
  truck_placeholder text,
  slip_date date,
  fuel_station text,
  litres numeric,
  amount numeric,
  vat_amount numeric,
  odometer numeric,
  notes text,
  document_url text,
  storage_path text,
  status text,
  created_at timestamptz,
  total_litres numeric,
  total_amount numeric,
  total_vat_amount numeric
)
language sql
security definer
set search_path = public
stable
as $$
  select
    fs.id,
    fs.job_id,
    tj.job_number,
    tj.public_reference,
    tj.job_status,
    fs.driver_name,
    fs.driver_placeholder,
    fs.truck_placeholder,
    fs.slip_date,
    fs.fuel_station,
    fs.litres,
    fs.amount,
    fs.vat_amount,
    fs.odometer,
    fs.notes,
    fs.document_url,
    fs.storage_path,
    fs.status,
    fs.created_at,
    sum(fs.litres) over () as total_litres,
    sum(fs.amount) over () as total_amount,
    sum(fs.vat_amount) over () as total_vat_amount
  from public.fuel_slips fs
  join public.transport_jobs tj on tj.id = fs.job_id
  where (
    public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
    or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
  )
  order by fs.slip_date desc, fs.created_at desc;
$$;

create or replace function public.ttaq_get_job_fuel_slips(target_transport_job_id uuid)
returns table (
  id uuid,
  job_id uuid,
  job_number text,
  public_reference text,
  job_status text,
  driver_name text,
  driver_placeholder text,
  truck_placeholder text,
  slip_date date,
  fuel_station text,
  litres numeric,
  amount numeric,
  vat_amount numeric,
  odometer numeric,
  notes text,
  document_url text,
  storage_path text,
  status text,
  created_at timestamptz,
  total_litres numeric,
  total_amount numeric,
  total_vat_amount numeric
)
language sql
security definer
set search_path = public
stable
as $$
  select
    fs.id,
    fs.job_id,
    tj.job_number,
    tj.public_reference,
    tj.job_status,
    fs.driver_name,
    fs.driver_placeholder,
    fs.truck_placeholder,
    fs.slip_date,
    fs.fuel_station,
    fs.litres,
    fs.amount,
    fs.vat_amount,
    fs.odometer,
    fs.notes,
    fs.document_url,
    fs.storage_path,
    fs.status,
    fs.created_at,
    sum(fs.litres) over () as total_litres,
    sum(fs.amount) over () as total_amount,
    sum(fs.vat_amount) over () as total_vat_amount
  from public.fuel_slips fs
  join public.transport_jobs tj on tj.id = fs.job_id
  where fs.job_id = target_transport_job_id
    and (
      public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
      or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
    )
  order by fs.slip_date desc, fs.created_at desc;
$$;
