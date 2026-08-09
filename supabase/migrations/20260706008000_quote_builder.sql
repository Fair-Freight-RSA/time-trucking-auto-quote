create extension if not exists pgcrypto;

create table if not exists public.quote_template_settings (
  id uuid primary key default gen_random_uuid(),
  setting_key text not null unique,
  setting_value jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.quote_documents (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  quote_number text not null,
  public_reference text not null,
  quote_date date not null default current_date,
  validity_date date not null,
  version_number integer not null default 1,
  status text not null default 'generated',
  final_selling_price numeric(14, 2) not null default 0,
  vat_amount numeric(14, 2) not null default 0,
  currency text not null default 'ZAR',
  accept_link text,
  decline_link text,
  pdf_placeholder_url text,
  customer_payload jsonb not null default '{}'::jsonb,
  document_payload jsonb not null default '{}'::jsonb,
  generated_by uuid references public.internal_users(id),
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (quote_request_id, version_number)
);

create table if not exists public.quote_customer_events (
  id uuid primary key default gen_random_uuid(),
  quote_document_id uuid references public.quote_documents(id) on delete cascade,
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  event_type text not null,
  event_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.quote_revision_requests (
  id uuid primary key default gen_random_uuid(),
  quote_document_id uuid references public.quote_documents(id) on delete cascade,
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  customer_name text,
  customer_email text,
  revision_message text,
  status text not null default 'requested',
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

drop trigger if exists ttaq_quote_template_settings_touch_updated_at on public.quote_template_settings;
create trigger ttaq_quote_template_settings_touch_updated_at
before update on public.quote_template_settings
for each row execute function public.ttaq_touch_updated_at();

drop trigger if exists ttaq_quote_documents_touch_updated_at on public.quote_documents;
create trigger ttaq_quote_documents_touch_updated_at
before update on public.quote_documents
for each row execute function public.ttaq_touch_updated_at();

create index if not exists quote_documents_quote_request_id_idx
on public.quote_documents(quote_request_id);

create index if not exists quote_documents_public_reference_idx
on public.quote_documents(public_reference);

create index if not exists quote_customer_events_quote_request_id_idx
on public.quote_customer_events(quote_request_id);

create index if not exists quote_revision_requests_quote_request_id_idx
on public.quote_revision_requests(quote_request_id);

alter table public.quote_template_settings enable row level security;
alter table public.quote_documents enable row level security;
alter table public.quote_customer_events enable row level security;
alter table public.quote_revision_requests enable row level security;

create policy "Internal users read quote template settings"
on public.quote_template_settings
for select
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Owner and manager manage quote template settings"
on public.quote_template_settings
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read quote documents"
on public.quote_documents
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create policy "Owner and manager manage quote documents"
on public.quote_documents
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read customer quote events"
on public.quote_customer_events
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create policy "Owner and manager manage customer quote events"
on public.quote_customer_events
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read quote revision requests"
on public.quote_revision_requests
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create policy "Owner and manager manage quote revision requests"
on public.quote_revision_requests
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

insert into public.quote_template_settings (setting_key, setting_value, is_active)
values (
  'default_quote_template',
  jsonb_build_object(
    'brand_name', 'Time Trucking',
    'brand_line', 'Professional transport solutions',
    'terms', array[
      'Quote is subject to final route, cargo, and availability confirmation.',
      'Pricing excludes delays, demurrage, storage, and additional services unless stated.',
      'Insurance is only included when explicitly selected and confirmed in writing.',
      'Acceptance confirms the customer wishes Time Trucking to proceed with load assignment.'
    ]
  ),
  true
)
on conflict (setting_key) do update
set setting_value = excluded.setting_value,
    is_active = true;

create or replace function public.ttaq_generate_quote_document(quote_request_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  request_record public.quote_requests%rowtype;
  recommendation public.vehicle_recommendations%rowtype;
  route_record public.route_estimates%rowtype;
  calculation public.pricing_calculations%rowtype;
  template jsonb;
  next_version integer;
  document_id uuid;
  validity_days integer := 7;
  validity_value date;
  quote_number_value text;
  final_price numeric(14, 2) := 0;
  vat_value numeric(14, 2) := 0;
  currency_value text := 'ZAR';
  stops_payload jsonb;
  cargo_payload jsonb;
  breakdown_payload jsonb;
  customer_payload_value jsonb;
  document_payload_value jsonb;
  public_ref text;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Only Time Trucking internal users with RFQ management access can generate quote documents.';
  end if;

  select *
    into request_record
  from public.quote_requests
  where id = $1;

  if request_record.id is null then
    raise exception 'Quote request not found: %', quote_request_id;
  end if;

  select *
    into recommendation
  from public.vehicle_recommendations
  where vehicle_recommendations.quote_request_id = request_record.id
  order by created_at desc
  limit 1;

  select *
    into route_record
  from public.route_estimates
  where route_estimates.quote_request_id = request_record.id
  order by created_at desc
  limit 1;

  select *
    into calculation
  from public.pricing_calculations
  where pricing_calculations.quote_request_id = request_record.id
  order by calculation_timestamp desc
  limit 1;

  select setting_value
    into template
  from public.quote_template_settings
  where setting_key = 'default_quote_template'
    and is_active = true
  limit 1;

  select quote_validity_days
    into validity_days
  from public.pricing_profiles
  where is_active = true
  order by updated_at desc
  limit 1;

  validity_days := coalesce(validity_days, 7);
  validity_value := current_date + validity_days;
  public_ref := coalesce(request_record.public_reference, 'TT-' || upper(left(replace(request_record.id::text, '-', ''), 8)));
  quote_number_value := public_ref || '-V' || (
    coalesce((select max(version_number) from public.quote_documents where quote_documents.quote_request_id = request_record.id), 0) + 1
  );

  next_version := coalesce((select max(version_number) from public.quote_documents where quote_documents.quote_request_id = request_record.id), 0) + 1;
  final_price := coalesce(request_record.adjusted_price, calculation.recommended_selling_price, calculation.grand_total, 0);
  vat_value := coalesce(calculation.vat_amount, 0);
  currency_value := coalesce(calculation.currency, 'ZAR');

  select coalesce(jsonb_agg(jsonb_build_object(
    'stop_order', qs.stop_order,
    'stop_type', qs.stop_type,
    'address', qs.address,
    'date_time_window', qs.date_time_window,
    'loading_method', qs.loading_method,
    'offloading_method', qs.offloading_method
  ) order by qs.stop_order asc), '[]'::jsonb)
    into stops_payload
  from public.quote_stops qs
  where qs.quote_request_id = request_record.id;

  if stops_payload = '[]'::jsonb then
    stops_payload := jsonb_build_array(
      jsonb_build_object('stop_order', 1, 'stop_type', 'collection', 'address', request_record.collection_address),
      jsonb_build_object('stop_order', 2, 'stop_type', 'delivery', 'address', request_record.delivery_address)
    );
  end if;

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
    'cargo_value', qi.cargo_value
  ) order by qi.created_at asc), '[]'::jsonb)
    into cargo_payload
  from public.quote_items qi
  where qi.quote_request_id = request_record.id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'line_key', pb.line_key,
    'line_label', pb.line_label,
    'quantity', pb.quantity,
    'unit_rate', pb.unit_rate,
    'amount', pb.amount,
    'explanation', pb.explanation
  ) order by pb.created_at asc), '[]'::jsonb)
    into breakdown_payload
  from public.pricing_breakdowns pb
  where pb.pricing_calculation_id = calculation.id;

  customer_payload_value := jsonb_build_object(
    'brand', coalesce(template, '{}'::jsonb),
    'quote_number', quote_number_value,
    'public_reference', public_ref,
    'quote_date', current_date,
    'validity_date', validity_value,
    'version_number', next_version,
    'customer', jsonb_build_object(
      'company_name', request_record.company_name,
      'contact_person', request_record.contact_person,
      'email', request_record.email,
      'phone', request_record.phone
    ),
    'stops', stops_payload,
    'cargo_items', cargo_payload,
    'route_estimate', jsonb_build_object(
      'origin_address', coalesce(route_record.origin_address, request_record.collection_address),
      'destination_address', coalesce(route_record.destination_address, request_record.delivery_address),
      'total_distance_km', coalesce(route_record.total_distance_km, 0),
      'total_duration_hours', coalesce(route_record.total_duration_hours, 0),
      'provider_name', coalesce(route_record.provider_name, 'manual_placeholder'),
      'route_notes', route_record.route_notes
    ),
    'transport', jsonb_build_object(
      'recommended_vehicle_type', coalesce(recommendation.recommended_vehicle_type, 'To be confirmed'),
      'recommended_trailer_type', coalesce(recommendation.recommended_trailer_type, 'To be confirmed'),
      'number_of_trucks', coalesce(recommendation.number_of_trucks, 1)
    ),
    'pricing', jsonb_build_object(
      'final_selling_price', final_price,
      'vat_amount', vat_value,
      'currency', currency_value
    ),
    'links', jsonb_build_object(
      'accept_link', './quote-view.html?ref=' || public_ref,
      'decline_link', './quote-view.html?ref=' || public_ref,
      'pdf_placeholder_url', './quote-placeholder.pdf'
    )
  );

  document_payload_value := customer_payload_value || jsonb_build_object(
    'internal_pricing_breakdown', breakdown_payload,
    'pricing_calculation_id', calculation.id,
    'vehicle_recommendation_id', recommendation.id,
    'route_estimate_id', route_record.id,
    'admin_notes', request_record.admin_notes
  );

  insert into public.quote_documents (
    quote_request_id,
    quote_number,
    public_reference,
    quote_date,
    validity_date,
    version_number,
    final_selling_price,
    vat_amount,
    currency,
    accept_link,
    decline_link,
    pdf_placeholder_url,
    customer_payload,
    document_payload,
    generated_by
  )
  values (
    request_record.id,
    quote_number_value,
    public_ref,
    current_date,
    validity_value,
    next_version,
    final_price,
    vat_value,
    currency_value,
    './quote-view.html?ref=' || public_ref,
    './quote-view.html?ref=' || public_ref,
    './quote-placeholder.pdf',
    customer_payload_value,
    document_payload_value,
    auth.uid()
  )
  returning id into document_id;

  return document_id;
end;
$$;

create or replace function public.ttaq_get_public_quote_document(
  raw_response_token text,
  public_reference_value text
)
returns table (
  quote_document_id uuid,
  quote_request_id uuid,
  quote_number text,
  public_reference text,
  quote_date date,
  validity_date date,
  version_number integer,
  status public.ttaq_quote_status,
  final_selling_price numeric,
  vat_amount numeric,
  currency text,
  accept_link text,
  decline_link text,
  pdf_placeholder_url text,
  customer_payload jsonb
)
language sql
security definer
set search_path = public
as $$
  select
    qd.id,
    qr.id,
    qd.quote_number,
    qd.public_reference,
    qd.quote_date,
    qd.validity_date,
    qd.version_number,
    qr.status,
    qd.final_selling_price,
    qd.vat_amount,
    qd.currency,
    qd.accept_link,
    qd.decline_link,
    qd.pdf_placeholder_url,
    qd.customer_payload
  from public.quote_documents qd
  join public.quote_requests qr on qr.id = qd.quote_request_id
  where qr.status in ('sent_to_client', 'client_accepted', 'client_declined')
    and qd.version_number = (
      select max(latest.version_number)
      from public.quote_documents latest
      where latest.quote_request_id = qd.quote_request_id
    )
    and (
      qr.response_token_hash = public.ttaq_hash_token(raw_response_token)
      or (
        public_reference_value is not null
        and qd.public_reference = public_reference_value
      )
    )
  limit 1;
$$;

create or replace function public.ttaq_request_quote_revision(
  raw_response_token text,
  public_reference_value text,
  revision_message_value text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  target_quote_request_id uuid;
  target_quote_document_id uuid;
  revision_id uuid;
begin
  select qr.id, qd.id
    into target_quote_request_id, target_quote_document_id
  from public.quote_documents qd
  join public.quote_requests qr on qr.id = qd.quote_request_id
  where qr.status = 'sent_to_client'
    and qd.version_number = (
      select max(latest.version_number)
      from public.quote_documents latest
      where latest.quote_request_id = qd.quote_request_id
    )
    and (
      qr.response_token_hash = public.ttaq_hash_token(raw_response_token)
      or (
        public_reference_value is not null
        and qd.public_reference = public_reference_value
      )
    )
  limit 1;

  if target_quote_request_id is null then
    raise exception 'Quote not found or not open for revision request';
  end if;

  insert into public.quote_revision_requests (
    quote_document_id,
    quote_request_id,
    revision_message
  )
  values (
    target_quote_document_id,
    target_quote_request_id,
    revision_message_value
  )
  returning id into revision_id;

  insert into public.quote_customer_events (
    quote_document_id,
    quote_request_id,
    event_type,
    event_payload
  )
  values (
    target_quote_document_id,
    target_quote_request_id,
    'revision_requested',
    jsonb_build_object('message', revision_message_value)
  );

  return revision_id;
end;
$$;
