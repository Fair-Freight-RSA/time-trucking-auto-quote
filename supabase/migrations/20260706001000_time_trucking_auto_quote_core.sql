create extension if not exists pgcrypto;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'ttaq_quote_status' and typnamespace = 'public'::regnamespace) then
    create type public.ttaq_quote_status as enum (
      'draft',
      'client_submitted',
      'admin_review',
      'adjusted',
      'approved',
      'sent_to_client',
      'client_accepted',
      'client_declined',
      'expired',
      'converted_to_load'
    );
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'ttaq_load_type' and typnamespace = 'public'::regnamespace) then
    create type public.ttaq_load_type as enum ('dedicated', 'part_load');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'ttaq_notification_status' and typnamespace = 'public'::regnamespace) then
    create type public.ttaq_notification_status as enum ('queued', 'sent', 'failed', 'cancelled');
  end if;
end $$;

create table public.admin_users (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  email text not null unique,
  role text not null default 'admin',
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.clients (
  id uuid primary key default gen_random_uuid(),
  company_name text not null,
  billing_email text,
  phone text,
  notes text,
  created_by uuid references public.admin_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.client_contacts (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id) on delete cascade,
  contact_person text not null,
  email text not null,
  phone text,
  is_primary boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.vehicle_types (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  max_weight_kg numeric(12, 2),
  max_volume_m3 numeric(12, 3),
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.trailer_types (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  max_weight_kg numeric(12, 2),
  max_volume_m3 numeric(12, 3),
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.quote_requests (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references public.clients(id) on delete set null,
  client_contact_id uuid references public.client_contacts(id) on delete set null,
  secure_token_hash text unique,
  status public.ttaq_quote_status not null default 'draft',
  company_name text not null,
  contact_person text not null,
  email text not null,
  phone text,
  collection_address text not null,
  delivery_address text not null,
  cargo_type text not null,
  load_description text not null,
  stackable boolean not null default false,
  load_type public.ttaq_load_type not null,
  loading_method text,
  offloading_method text,
  goods_value numeric(14, 2),
  insurance_required boolean not null default false,
  collection_date date,
  delivery_date date,
  special_requirements text,
  attachment_note text,
  suggested_vehicle_type_id uuid references public.vehicle_types(id),
  suggested_trailer_type_id uuid references public.trailer_types(id),
  suggestion_notes text,
  admin_notes text,
  expires_at timestamptz,
  created_by uuid references public.admin_users(id),
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  updated_at timestamptz not null default now()
);

create table public.quote_items (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  description text,
  quantity integer not null check (quantity > 0),
  length_m numeric(10, 3),
  width_m numeric(10, 3),
  height_m numeric(10, 3),
  weight_kg numeric(12, 2),
  created_at timestamptz not null default now()
);

create table public.pricing_rules (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  vehicle_type_id uuid references public.vehicle_types(id),
  trailer_type_id uuid references public.trailer_types(id),
  base_rate numeric(14, 2),
  per_km_rate numeric(14, 2),
  per_kg_rate numeric(14, 4),
  minimum_charge numeric(14, 2),
  insurance_percentage numeric(7, 4),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.quote_versions (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  version_number integer not null,
  status public.ttaq_quote_status not null default 'adjusted',
  vehicle_type_id uuid references public.vehicle_types(id),
  trailer_type_id uuid references public.trailer_types(id),
  transport_price numeric(14, 2),
  insurance_price numeric(14, 2),
  additional_price numeric(14, 2),
  total_price numeric(14, 2),
  admin_notes text,
  client_notes text,
  approved_by uuid references public.admin_users(id),
  approved_at timestamptz,
  sent_at timestamptz,
  client_responded_at timestamptz,
  created_at timestamptz not null default now(),
  unique (quote_request_id, version_number)
);

create table public.quote_status_events (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  from_status public.ttaq_quote_status,
  to_status public.ttaq_quote_status not null,
  note text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid references public.quote_requests(id) on delete cascade,
  recipient_email text not null,
  notification_type text not null,
  status public.ttaq_notification_status not null default 'queued',
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);

create table public.email_logs (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid references public.notifications(id) on delete set null,
  quote_request_id uuid references public.quote_requests(id) on delete set null,
  recipient_email text not null,
  subject text not null,
  provider text,
  provider_message_id text,
  status public.ttaq_notification_status not null default 'queued',
  error_message text,
  created_at timestamptz not null default now()
);

create or replace function public.ttaq_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger ttaq_clients_touch_updated_at
before update on public.clients
for each row execute function public.ttaq_touch_updated_at();

create trigger ttaq_quote_requests_touch_updated_at
before update on public.quote_requests
for each row execute function public.ttaq_touch_updated_at();

create trigger ttaq_pricing_rules_touch_updated_at
before update on public.pricing_rules
for each row execute function public.ttaq_touch_updated_at();

alter table public.admin_users enable row level security;
alter table public.clients enable row level security;
alter table public.client_contacts enable row level security;
alter table public.quote_requests enable row level security;
alter table public.quote_items enable row level security;
alter table public.quote_status_events enable row level security;
alter table public.vehicle_types enable row level security;
alter table public.trailer_types enable row level security;
alter table public.pricing_rules enable row level security;
alter table public.quote_versions enable row level security;
alter table public.notifications enable row level security;
alter table public.email_logs enable row level security;

create policy "Admin users can manage admin_users"
on public.admin_users for all
using (auth.uid() = id or exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active))
with check (auth.uid() = id or exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active));

create policy "Admins manage clients"
on public.clients for all
using (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active))
with check (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active));

create policy "Admins manage client_contacts"
on public.client_contacts for all
using (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active))
with check (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active));

create policy "Admins manage quote_requests"
on public.quote_requests for all
using (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active))
with check (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active));

create policy "Admins manage quote_items"
on public.quote_items for all
using (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active))
with check (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active));

create policy "Admins manage quote_status_events"
on public.quote_status_events for all
using (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active))
with check (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active));

create policy "Admins manage vehicle_types"
on public.vehicle_types for all
using (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active))
with check (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active));

create policy "Admins manage trailer_types"
on public.trailer_types for all
using (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active))
with check (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active));

create policy "Admins manage pricing_rules"
on public.pricing_rules for all
using (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active))
with check (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active));

create policy "Admins manage quote_versions"
on public.quote_versions for all
using (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active))
with check (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active));

create policy "Admins manage notifications"
on public.notifications for all
using (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active))
with check (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active));

create policy "Admins manage email_logs"
on public.email_logs for all
using (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active))
with check (exists (select 1 from public.admin_users au where au.id = auth.uid() and au.is_active));

create index ttaq_clients_company_name_idx on public.clients(company_name);
create index ttaq_client_contacts_client_id_idx on public.client_contacts(client_id);
create index ttaq_quote_requests_status_idx on public.quote_requests(status);
create index ttaq_quote_requests_secure_token_hash_idx on public.quote_requests(secure_token_hash);
create index ttaq_quote_items_quote_request_id_idx on public.quote_items(quote_request_id);
create index ttaq_quote_versions_quote_request_id_idx on public.quote_versions(quote_request_id);
create index ttaq_status_events_quote_request_id_idx on public.quote_status_events(quote_request_id);
create index ttaq_notifications_status_idx on public.notifications(status);
create index ttaq_email_logs_quote_request_id_idx on public.email_logs(quote_request_id);

insert into public.vehicle_types (name, max_weight_kg, max_volume_m3, notes)
values
  ('1-ton bakkie / panel van', 1000, 6, 'Small urgent freight and light loads'),
  ('4-ton truck', 4000, 22, 'Moderate loads and regional freight'),
  ('8-ton truck', 8000, 45, 'Heavier palletized freight'),
  ('Dedicated truck', null, null, 'Dedicated vehicle review required');

insert into public.trailer_types (name, max_weight_kg, max_volume_m3, notes)
values
  ('Closed body', 1000, 6, 'Protected small freight'),
  ('Curtain side body', 4000, 22, 'General freight access'),
  ('Tautliner', 34000, 90, 'High volume linehaul freight'),
  ('Superlink / tautliner review', 34000, 100, 'Admin review required');
