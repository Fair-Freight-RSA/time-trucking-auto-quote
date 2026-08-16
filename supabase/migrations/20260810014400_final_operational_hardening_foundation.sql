do $$
begin
  if not exists (select 1 from pg_type where typname = 'ttaq_review_status' and typnamespace = 'public'::regnamespace) then
    create type public.ttaq_review_status as enum ('ready', 'pending', 'review_required', 'blocking', 'manual', 'inactive');
  end if;
end $$;

create table if not exists public.internal_user_invitations (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  full_name text,
  phone text,
  role public.ttaq_internal_role not null default 'viewer',
  permissions jsonb not null default '{}'::jsonb,
  invitation_status text not null default 'pending',
  auth_user_id uuid references auth.users(id),
  invited_by uuid references public.internal_users(id),
  invited_at timestamptz not null default now(),
  accepted_at timestamptz,
  last_sent_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint internal_user_invitations_status_check check (invitation_status in ('pending', 'sent', 'accepted', 'failed', 'revoked'))
);

create unique index if not exists ttaq_internal_user_invitations_pending_email_idx
on public.internal_user_invitations (lower(email))
where invitation_status in ('pending', 'sent', 'failed');

create table if not exists public.company_operating_depots (
  id uuid primary key default gen_random_uuid(),
  display_name text not null,
  full_address text not null,
  google_place_id text,
  latitude numeric(10, 7),
  longitude numeric(10, 7),
  is_default boolean not null default false,
  is_active boolean not null default true,
  source_basis text not null default 'Configured by Time Trucking',
  created_by uuid references public.internal_users(id),
  updated_by uuid references public.internal_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint company_operating_depots_coordinate_pair_check check ((latitude is null and longitude is null) or (latitude is not null and longitude is not null))
);

create unique index if not exists ttaq_company_operating_depots_one_default_idx
on public.company_operating_depots (is_default)
where is_default and is_active;

alter table public.quote_requests
  add column if not exists operating_depot_id uuid references public.company_operating_depots(id),
  add column if not exists return_load_status text not null default 'none',
  add column if not exists return_load_pricing_status public.ttaq_review_status not null default 'review_required',
  add column if not exists return_load_notes text,
  add column if not exists commercial_billable_distance_basis text not null default 'pending_henning_confirmation',
  add column if not exists manual_night_out_count numeric(8, 2),
  add column if not exists operational_review_status public.ttaq_review_status not null default 'review_required',
  add column if not exists operational_review_notes text,
  add constraint quote_requests_return_load_status_check
    check (return_load_status in ('none', 'available', 'unknown_review_required'));

create table if not exists public.quote_operational_journey_legs (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  leg_key text not null,
  leg_order integer not null,
  leg_label text not null,
  origin_address text,
  destination_address text,
  origin_place_id text,
  destination_place_id text,
  origin_latitude numeric(10, 7),
  origin_longitude numeric(10, 7),
  destination_latitude numeric(10, 7),
  destination_longitude numeric(10, 7),
  distance_km numeric(12, 3),
  duration_hours numeric(12, 3),
  load_status text not null default 'unknown',
  backload_status text not null default 'none',
  toll_status public.ttaq_review_status not null default 'review_required',
  toll_amount numeric(14, 2),
  countries jsonb not null default '[]'::jsonb,
  border_crossings jsonb not null default '[]'::jsonb,
  route_risk_status public.ttaq_review_status not null default 'review_required',
  route_provider text,
  provider_source text,
  provider_response jsonb not null default '{}'::jsonb,
  geometry jsonb,
  retrieved_at timestamptz,
  review_status public.ttaq_review_status not null default 'review_required',
  review_reason text not null default 'Operational leg requires route evidence before automatic internal economics.',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint quote_operational_journey_legs_key_check check (leg_key in ('positioning_outbound', 'loaded_delivery', 'return_to_depot')),
  constraint quote_operational_journey_legs_load_status_check check (load_status in ('empty', 'loaded', 'backload', 'unknown')),
  constraint quote_operational_journey_legs_backload_status_check check (backload_status in ('none', 'available', 'unknown_review_required'))
);

create unique index if not exists ttaq_quote_operational_journey_legs_unique_idx
on public.quote_operational_journey_legs (quote_request_id, leg_key);

create table if not exists public.quote_manual_external_costs (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  pricing_calculation_id uuid references public.pricing_calculations(id) on delete set null,
  cost_type text not null,
  supplier text,
  description text not null,
  cost_amount numeric(14, 2),
  commercial_charge_amount numeric(14, 2),
  vat_treatment text not null default 'review_required',
  source_basis text not null default 'Manual quote-specific external cost',
  reference_number text,
  notes text,
  review_status public.ttaq_review_status not null default 'review_required',
  created_by uuid references public.internal_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint quote_manual_external_costs_type_check check (cost_type in ('crane', 'third_party_handling', 'refrigeration', 'high_value_insurance', 'permit', 'cross_border', 'route_risk', 'other')),
  constraint quote_manual_external_costs_amounts_check check ((cost_amount is null or cost_amount >= 0) and (commercial_charge_amount is null or commercial_charge_amount >= 0))
);

create table if not exists public.vat_rate_authorities (
  id uuid primary key default gen_random_uuid(),
  jurisdiction text not null default 'ZA',
  vat_rate_percent numeric(7, 4) not null,
  authority text not null,
  source_label text not null,
  source_url text not null,
  effective_from date not null,
  effective_to date,
  last_verified_at timestamptz not null default now(),
  is_active boolean not null default true,
  override_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint vat_rate_authorities_rate_check check (vat_rate_percent >= 0)
);

create unique index if not exists ttaq_vat_rate_authorities_one_active_idx
on public.vat_rate_authorities (jurisdiction)
where is_active and effective_to is null;

insert into public.vat_rate_authorities (
  jurisdiction, vat_rate_percent, authority, source_label, source_url, effective_from, last_verified_at, is_active
)
values (
  'ZA',
  15.0000,
  'South African Revenue Service (SARS)',
  'SARS Value-Added Tax rate page: standard VAT rate currently 15%',
  'https://www.sars.gov.za/types-of-tax/value-added-tax/',
  date '2018-04-01',
  now(),
  true
)
on conflict do nothing;

create table if not exists public.cross_border_external_charge_sources (
  id uuid primary key default gen_random_uuid(),
  source_key text not null unique,
  charge_category text not null,
  country_code text,
  authority text not null,
  source_url text,
  status public.ttaq_review_status not null default 'review_required',
  last_verified_at timestamptz,
  notes text not null default 'No automatic fee is charged until official applicability and amount are verified.',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.permit_fee_catalogue (
  id uuid primary key default gen_random_uuid(),
  permit_type text not null,
  issuing_authority text not null,
  jurisdiction text not null,
  applicability_criteria jsonb not null default '{}'::jsonb,
  official_amount numeric(14, 2),
  currency text not null default 'ZAR',
  vat_treatment text not null default 'review_required',
  source_label text,
  source_url text,
  effective_from date,
  effective_to date,
  source_status public.ttaq_review_status not null default 'review_required',
  notes text not null default 'Manual permit cost required unless official fixed fee and applicability are verified.',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.cargo_insurance_profiles (
  id uuid primary key default gen_random_uuid(),
  provider_name text not null,
  standard_cover_threshold numeric(14, 2),
  additional_cover_threshold numeric(14, 2),
  approved_rate_formula jsonb,
  minimum_premium numeric(14, 2),
  maximum_cover numeric(14, 2),
  excess_description text,
  commodity_restrictions text,
  route_security_conditions text,
  vat_treatment text not null default 'review_required',
  source_basis text not null default 'Requires Time Trucking insurer/policy input',
  effective_from date,
  effective_to date,
  source_status public.ttaq_review_status not null default 'review_required',
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.contextual_help_topics (
  id uuid primary key default gen_random_uuid(),
  topic_key text not null unique,
  topic_title text not null,
  plain_language_summary text not null,
  operational_guidance text not null,
  review_required_when text,
  applies_to text[] not null default array[]::text[],
  is_active boolean not null default true,
  updated_at timestamptz not null default now()
);

insert into public.contextual_help_topics (topic_key, topic_title, plain_language_summary, operational_guidance, review_required_when, applies_to)
values
  ('commercial_vs_internal_cost', 'Commercial price vs internal cost', 'Customer price starts from the Time Trucking commercial rate card. Internal costs are only for contribution analysis.', 'Do not add normal fuel, tyres, maintenance, depreciation, driver cost or normal profit on top of Henning''s commercial rates.', 'Internal cost inputs are missing or a manager wants to inspect profitability.', array['pricing','quote_review']),
  ('day_vs_km', 'Day rate vs R/km', 'The system shows both scenarios, but Henning has not confirmed the rule for choosing between them.', 'Keep quotes review-required until an authorised manager selects or confirms the commercial base.', 'DAY VS KM PRICING RULE REQUIRES HENNING CONFIRMATION.', array['pricing','quote_review']),
  ('return_load', 'Return load / backload', 'A return load may affect job economics, but no commercial discount or recovery rule is approved yet.', 'Select the quote-level backload status. Do not remove the return leg from pricing without an approved rule.', 'RETURN LOAD PRICING RULE REQUIRES REVIEW.', array['quote_review']),
  ('crane', 'Crane cost', 'Crane work is quote-specific and must not use an invented average price.', 'Enter a supplier, reference and amount when a crane is required.', 'BLOCKING - MANUAL CRANE COST REQUIRED.', array['quote_review','pricing']),
  ('high_value_insurance', 'High-value cargo insurance', 'Insurance charges require Time Trucking policy or insurer information.', 'Record declared value and manual insurer cost unless an approved insurer formula exists.', 'HIGH-VALUE CARGO INSURANCE REQUIRES REVIEW.', array['quote_review','pricing']),
  ('vat', 'South African VAT', 'SARS standard VAT is stored as an auditable source record. Historical quotes keep their own VAT snapshot.', 'Show subtotal excluding VAT, VAT and final amount including VAT. Be careful with VAT-inclusive toll inputs.', 'VAT source or manual override requires review.', array['pricing','quote_review']),
  ('tolls', 'Automatic tolls', 'Official toll tariffs are used where route matching is reliable. Missing toll evidence requires review.', 'Inspect details only when needed; unresolved tolls must not become R0.', 'Toll class, route geometry or tariff coverage is incomplete.', array['pricing','quote_review']),
  ('haz', 'HAZ vs non-HAZ', 'Hazardous cargo selects the HAZ commercial rate card row.', 'Do not stack a generic hazmat surcharge on top of the HAZ commercial rate.', 'Separate permits, escort or statutory costs may still require review.', array['quote_review','pricing'])
on conflict (topic_key) do update
set topic_title = excluded.topic_title,
    plain_language_summary = excluded.plain_language_summary,
    operational_guidance = excluded.operational_guidance,
    review_required_when = excluded.review_required_when,
    applies_to = excluded.applies_to,
    is_active = true,
    updated_at = now();

alter table public.internal_user_invitations enable row level security;
alter table public.company_operating_depots enable row level security;
alter table public.quote_operational_journey_legs enable row level security;
alter table public.quote_manual_external_costs enable row level security;
alter table public.vat_rate_authorities enable row level security;
alter table public.cross_border_external_charge_sources enable row level security;
alter table public.permit_fee_catalogue enable row level security;
alter table public.cargo_insurance_profiles enable row level security;
alter table public.contextual_help_topics enable row level security;

drop policy if exists "Pricing managers manage user invitations" on public.internal_user_invitations;
create policy "Pricing managers manage user invitations" on public.internal_user_invitations for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_users'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_users'));

drop policy if exists "Internal users read company depots" on public.company_operating_depots;
create policy "Internal users read company depots" on public.company_operating_depots for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));
drop policy if exists "Admins manage company depots" on public.company_operating_depots;
create policy "Admins manage company depots" on public.company_operating_depots for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

drop policy if exists "Internal users read operational journey legs" on public.quote_operational_journey_legs;
create policy "Internal users read operational journey legs" on public.quote_operational_journey_legs for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));
drop policy if exists "Managers manage operational journey legs" on public.quote_operational_journey_legs;
create policy "Managers manage operational journey legs" on public.quote_operational_journey_legs for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

drop policy if exists "Internal users read manual external costs" on public.quote_manual_external_costs;
create policy "Internal users read manual external costs" on public.quote_manual_external_costs for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));
drop policy if exists "Managers manage manual external costs" on public.quote_manual_external_costs;
create policy "Managers manage manual external costs" on public.quote_manual_external_costs for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') or public.ttaq_has_internal_permission(auth.uid(), 'adjust_pricing'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') or public.ttaq_has_internal_permission(auth.uid(), 'adjust_pricing'));

drop policy if exists "Internal users read VAT authorities" on public.vat_rate_authorities;
create policy "Internal users read VAT authorities" on public.vat_rate_authorities for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));
drop policy if exists "Pricing managers manage VAT authorities" on public.vat_rate_authorities;
create policy "Pricing managers manage VAT authorities" on public.vat_rate_authorities for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read external charge catalogues" on public.cross_border_external_charge_sources;
create policy "Internal users read external charge catalogues" on public.cross_border_external_charge_sources for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));
drop policy if exists "Pricing managers manage external charge catalogues" on public.cross_border_external_charge_sources;
create policy "Pricing managers manage external charge catalogues" on public.cross_border_external_charge_sources for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read permit catalogue" on public.permit_fee_catalogue;
create policy "Internal users read permit catalogue" on public.permit_fee_catalogue for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));
drop policy if exists "Pricing managers manage permit catalogue" on public.permit_fee_catalogue;
create policy "Pricing managers manage permit catalogue" on public.permit_fee_catalogue for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read cargo insurance profiles" on public.cargo_insurance_profiles;
create policy "Internal users read cargo insurance profiles" on public.cargo_insurance_profiles for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));
drop policy if exists "Pricing managers manage cargo insurance profiles" on public.cargo_insurance_profiles;
create policy "Pricing managers manage cargo insurance profiles" on public.cargo_insurance_profiles for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Authenticated internal users read help topics" on public.contextual_help_topics;
create policy "Authenticated internal users read help topics" on public.contextual_help_topics for select
using (auth.uid() is not null and exists (select 1 from public.internal_users iu where iu.id = auth.uid() and iu.user_status = 'active'));
drop policy if exists "Pricing managers manage help topics" on public.contextual_help_topics;
create policy "Pricing managers manage help topics" on public.contextual_help_topics for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

create or replace function public.ttaq_quote_operational_journey_summary(target_quote_request_id uuid)
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
  with quote as (
    select qr.*, depot.display_name as depot_name, depot.full_address as depot_address
    from public.quote_requests qr
    left join public.company_operating_depots depot on depot.id = qr.operating_depot_id
    where qr.id = target_quote_request_id
      and (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
  ),
  legs as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'leg_key', leg_key,
      'leg_label', leg_label,
      'origin_address', origin_address,
      'destination_address', destination_address,
      'distance_km', distance_km,
      'duration_hours', duration_hours,
      'load_status', load_status,
      'backload_status', backload_status,
      'toll_status', toll_status,
      'route_risk_status', route_risk_status,
      'review_status', review_status,
      'review_reason', review_reason
    ) order by leg_order), '[]'::jsonb) as payload,
    sum(coalesce(distance_km, 0)) as total_distance,
    sum(coalesce(duration_hours, 0)) as total_duration
    from public.quote_operational_journey_legs
    where quote_request_id = target_quote_request_id
  )
  select coalesce(jsonb_build_object(
    'depot_name', quote.depot_name,
    'depot_address', quote.depot_address,
    'return_load_status', quote.return_load_status,
    'return_load_pricing_status', quote.return_load_pricing_status,
    'commercial_billable_distance_basis', quote.commercial_billable_distance_basis,
    'operational_review_status', quote.operational_review_status,
    'operational_review_notes', quote.operational_review_notes,
    'total_operational_km', legs.total_distance,
    'total_operational_duration_hours', legs.total_duration,
    'legs', legs.payload,
    'commercial_treatment', 'Operational journey is separate from commercial billable distance until Henning confirms day-vs-km and return-trip rules'
  ), '{}'::jsonb)
  from quote
  cross join legs;
$$;

grant execute on function public.ttaq_quote_operational_journey_summary(uuid) to authenticated;

create or replace function public.ttaq_save_default_operating_depot(depot_payload jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  saved_id uuid;
  depot_name text := nullif(btrim(depot_payload ->> 'display_name'), '');
  depot_address text := nullif(btrim(depot_payload ->> 'full_address'), '');
  depot_place_id text := nullif(btrim(depot_payload ->> 'google_place_id'), '');
  depot_latitude numeric := nullif(btrim(depot_payload ->> 'latitude'), '')::numeric;
  depot_longitude numeric := nullif(btrim(depot_payload ->> 'longitude'), '')::numeric;
begin
  if not (
    public.ttaq_has_internal_permission(current_user_id, 'manage_pricing_rules')
    or public.ttaq_has_internal_permission(current_user_id, 'manage_rfqs')
  ) then
    raise exception 'Not allowed to manage operating depots';
  end if;

  if depot_name is null or depot_address is null then
    raise exception 'Default depot name and address are required';
  end if;

  update public.company_operating_depots
     set is_default = false,
         updated_by = current_user_id,
         updated_at = now()
   where is_default = true
     and is_active = true;

  insert into public.company_operating_depots (
    display_name,
    full_address,
    google_place_id,
    latitude,
    longitude,
    is_default,
    is_active,
    source_basis,
    created_by,
    updated_by
  )
  values (
    depot_name,
    depot_address,
    depot_place_id,
    depot_latitude,
    depot_longitude,
    true,
    true,
    'Configured by Time Trucking admin settings',
    current_user_id,
    current_user_id
  )
  returning id into saved_id;

  return saved_id;
end;
$$;

revoke all on function public.ttaq_save_default_operating_depot(jsonb) from public;
revoke all on function public.ttaq_save_default_operating_depot(jsonb) from anon;
grant execute on function public.ttaq_save_default_operating_depot(jsonb) to authenticated;

create or replace function public.ttaq_update_quote_return_load_status(
  target_quote_request_id uuid,
  return_load_status_value text,
  notes_value text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Not allowed to update return-load status';
  end if;

  if return_load_status_value not in ('none', 'available', 'unknown_review_required') then
    raise exception 'Unknown return-load status';
  end if;

  update public.quote_requests
     set return_load_status = return_load_status_value,
         return_load_pricing_status = case when return_load_status_value = 'available' then 'review_required'::public.ttaq_review_status else 'review_required'::public.ttaq_review_status end,
         return_load_notes = notes_value,
         operational_review_status = 'review_required',
         operational_review_notes = 'Return load/backload commercial treatment requires Henning-approved rule.',
         updated_at = now()
   where id = target_quote_request_id;

  insert into public.quote_status_events (quote_request_id, from_status, to_status, note, created_by)
  select target_quote_request_id, status, status, 'Return-load status changed to ' || return_load_status_value || coalesce(': ' || notes_value, ''), auth.uid()
  from public.quote_requests
  where id = target_quote_request_id;
end;
$$;

revoke all on function public.ttaq_update_quote_return_load_status(uuid, text, text) from public;
revoke all on function public.ttaq_update_quote_return_load_status(uuid, text, text) from anon;
grant execute on function public.ttaq_update_quote_return_load_status(uuid, text, text) to authenticated;

update public.pricing_settings
   set setting_value = 0,
       description = case setting_key
         when 'hazmat_surcharge' then 'Deprecated: HAZ cargo selects HAZ commercial rate; no generic hazmat surcharge is stacked.'
         when 'refrigeration_surcharge' then 'Deprecated: refrigeration commercial amount is quote-specific/manual review unless approved equipment/rule exists.'
         when 'crane_surcharge' then 'Deprecated: crane cost is quote-specific/manual review; no invented average price.'
         when 'forklift_surcharge' then 'Deprecated: forklift is operational information unless Time Trucking arranges a third-party handling cost.'
         when 'high_value_surcharge' then 'Deprecated: high-value insurance requires approved insurer formula or manual cost.'
         when 'high_value_threshold' then 'Declared cargo value remains captured, but no generic automatic high-value surcharge is active.'
         else description
       end
 where setting_key in ('hazmat_surcharge', 'refrigeration_surcharge', 'crane_surcharge', 'forklift_surcharge', 'high_value_surcharge', 'high_value_threshold');

comment on table public.company_operating_depots is 'Time Trucking operating bases/depots used to model depot -> pickup -> delivery -> depot journeys. No depot should be hardcoded in client code.';
comment on table public.quote_operational_journey_legs is 'Three-leg operational journey evidence. Commercial billable distance remains separate until Henning confirms day/km and return-trip rules.';
comment on table public.quote_manual_external_costs is 'Quote-specific external/manual costs such as crane, third-party handling, permits, insurance and cross-border costs. Missing costs remain review-required, not R0.';
