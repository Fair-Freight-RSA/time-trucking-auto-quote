create extension if not exists pgcrypto;

alter table public.quote_requests
  add column if not exists public_reference text unique,
  add column if not exists response_token_hash text unique,
  add column if not exists adjusted_price numeric(14, 2),
  add column if not exists quote_sent_at timestamptz,
  add column if not exists client_responded_at timestamptz;

create index if not exists ttaq_quote_requests_public_reference_idx
  on public.quote_requests(public_reference);

create index if not exists ttaq_quote_requests_response_token_hash_idx
  on public.quote_requests(response_token_hash);

create or replace function public.ttaq_hash_token(raw_token text)
returns text
language sql
stable
as $$
  select case
    when raw_token is null or length(raw_token) = 0 then null
    else encode(extensions.digest(raw_token::bytea, 'sha256'), 'hex')
  end;
$$;

create or replace function public.ttaq_public_reference()
returns text
language sql
volatile
as $$
  select 'TTAQ-' || to_char(now(), 'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
$$;

create or replace function public.ttaq_submit_public_rfq(
  raw_rfq_token text,
  raw_response_token text,
  payload jsonb
)
returns table (
  quote_request_id uuid,
  public_reference text,
  response_token text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  existing_request_id uuid;
  client_record_id uuid;
  contact_record_id uuid;
  target_quote_request_id uuid;
  new_reference text;
  old_status public.ttaq_quote_status;
begin
  if raw_response_token is null or length(raw_response_token) = 0 then
    raise exception 'Missing quote response token';
  end if;

  select id, status
    into existing_request_id, old_status
  from public.quote_requests
  where secure_token_hash = public.ttaq_hash_token(raw_rfq_token)
    and status in ('draft', 'client_submitted')
    and (expires_at is null or expires_at > now())
  limit 1;

  insert into public.clients (company_name, billing_email, phone)
  values (
    payload->>'company_name',
    payload->>'email',
    payload->>'phone'
  )
  returning id into client_record_id;

  insert into public.client_contacts (client_id, contact_person, email, phone, is_primary)
  values (
    client_record_id,
    payload->>'contact_person',
    payload->>'email',
    payload->>'phone',
    true
  )
  returning id into contact_record_id;

  new_reference := coalesce(nullif(payload->>'public_reference', ''), public.ttaq_public_reference());

  if existing_request_id is null then
    insert into public.quote_requests (
      client_id,
      client_contact_id,
      status,
      public_reference,
      response_token_hash,
      company_name,
      contact_person,
      email,
      phone,
      collection_address,
      delivery_address,
      cargo_type,
      load_description,
      stackable,
      load_type,
      loading_method,
      offloading_method,
      goods_value,
      insurance_required,
      collection_date,
      delivery_date,
      special_requirements,
      attachment_note,
      suggestion_notes,
      submitted_at
    )
    values (
      client_record_id,
      contact_record_id,
      'admin_review',
      new_reference,
      public.ttaq_hash_token(raw_response_token),
      payload->>'company_name',
      payload->>'contact_person',
      payload->>'email',
      payload->>'phone',
      payload->>'collection_address',
      payload->>'delivery_address',
      payload->>'cargo_type',
      payload->>'load_description',
      coalesce((payload->>'stackable')::boolean, false),
      (payload->>'load_type')::public.ttaq_load_type,
      payload->>'loading_method',
      payload->>'offloading_method',
      nullif(payload->>'goods_value', '')::numeric,
      coalesce((payload->>'insurance_required')::boolean, false),
      nullif(payload->>'collection_date', '')::date,
      nullif(payload->>'delivery_date', '')::date,
      payload->>'special_requirements',
      payload->>'attachment_note',
      payload->>'suggestion_notes',
      now()
    )
    returning id into target_quote_request_id;
    old_status := 'draft';
  else
    update public.quote_requests
       set client_id = client_record_id,
           client_contact_id = contact_record_id,
           status = 'admin_review',
           public_reference = coalesce(public.quote_requests.public_reference, new_reference),
           response_token_hash = public.ttaq_hash_token(raw_response_token),
           company_name = payload->>'company_name',
           contact_person = payload->>'contact_person',
           email = payload->>'email',
           phone = payload->>'phone',
           collection_address = payload->>'collection_address',
           delivery_address = payload->>'delivery_address',
           cargo_type = payload->>'cargo_type',
           load_description = payload->>'load_description',
           stackable = coalesce((payload->>'stackable')::boolean, false),
           load_type = (payload->>'load_type')::public.ttaq_load_type,
           loading_method = payload->>'loading_method',
           offloading_method = payload->>'offloading_method',
           goods_value = nullif(payload->>'goods_value', '')::numeric,
           insurance_required = coalesce((payload->>'insurance_required')::boolean, false),
           collection_date = nullif(payload->>'collection_date', '')::date,
           delivery_date = nullif(payload->>'delivery_date', '')::date,
           special_requirements = payload->>'special_requirements',
           attachment_note = payload->>'attachment_note',
           suggestion_notes = payload->>'suggestion_notes',
           submitted_at = now()
     where id = existing_request_id
     returning id, public.quote_requests.public_reference into target_quote_request_id, new_reference;
  end if;

  delete from public.quote_items where quote_items.quote_request_id = target_quote_request_id;

  insert into public.quote_items (
    quote_request_id,
    description,
    quantity,
    length_m,
    width_m,
    height_m,
    weight_kg
  )
  values (
    target_quote_request_id,
    payload->>'load_description',
    coalesce((payload->>'quantity')::integer, 1),
    nullif(payload->>'length_m', '')::numeric,
    nullif(payload->>'width_m', '')::numeric,
    nullif(payload->>'height_m', '')::numeric,
    nullif(payload->>'weight_kg', '')::numeric
  );

  insert into public.quote_status_events (quote_request_id, from_status, to_status, note)
  values (target_quote_request_id, old_status, 'admin_review', 'Public RFQ submitted');

  insert into public.notifications (quote_request_id, recipient_email, notification_type, payload)
  values (
    target_quote_request_id,
    'admin@timetrucking.co.za',
    'rfq_submitted_placeholder',
    jsonb_build_object('public_reference', new_reference)
  );

  quote_request_id := target_quote_request_id;
  public_reference := new_reference;
  response_token := raw_response_token;
  return next;
end;
$$;

create or replace function public.ttaq_create_internal_rfq_link(
  raw_rfq_token text,
  company_name_value text,
  email_value text,
  public_reference_value text,
  expires_on_value date
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  created_id uuid;
  reference_value text;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Not allowed to create RFQ links';
  end if;

  reference_value := coalesce(nullif(public_reference_value, ''), public.ttaq_public_reference());

  insert into public.quote_requests (
    secure_token_hash,
    status,
    public_reference,
    company_name,
    contact_person,
    email,
    phone,
    collection_address,
    delivery_address,
    cargo_type,
    load_description,
    load_type,
    expires_at,
    created_by_internal_user_id
  )
  values (
    public.ttaq_hash_token(raw_rfq_token),
    'draft',
    reference_value,
    company_name_value,
    'Pending client submission',
    email_value,
    '',
    'Pending client submission',
    'Pending client submission',
    'Pending client submission',
    'Pending client submission',
    'dedicated',
    case when expires_on_value is null then null else expires_on_value::timestamptz end,
    auth.uid()
  )
  returning id into created_id;

  insert into public.quote_status_events (quote_request_id, from_status, to_status, note, created_by)
  values (created_id, null, 'draft', 'Internal RFQ link created', auth.uid());

  return created_id;
end;
$$;

create or replace function public.ttaq_update_internal_quote_review(
  target_quote_request_id uuid,
  admin_notes_value text,
  adjusted_price_value numeric,
  next_status public.ttaq_quote_status
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  old_status public.ttaq_quote_status;
  next_version integer;
begin
  if next_status not in ('approved', 'sent_to_client') then
    raise exception 'Invalid review status';
  end if;

  if not public.ttaq_can_approve_quotes(auth.uid()) then
    raise exception 'Only owner or manager can approve or send quotes';
  end if;

  select status into old_status
  from public.quote_requests
  where id = target_quote_request_id;

  update public.quote_requests
     set admin_notes = admin_notes_value,
         adjusted_price = adjusted_price_value,
         status = next_status,
         quote_sent_at = case when next_status = 'sent_to_client' then now() else quote_sent_at end
   where id = target_quote_request_id;

  select coalesce(max(version_number), 0) + 1
    into next_version
  from public.quote_versions
  where quote_versions.quote_request_id = target_quote_request_id;

  insert into public.quote_versions (
    quote_request_id,
    version_number,
    status,
    total_price,
    admin_notes,
    approved_by_internal_user_id,
    approved_at,
    sent_at
  )
  values (
    target_quote_request_id,
    next_version,
    next_status,
    adjusted_price_value,
    admin_notes_value,
    auth.uid(),
    now(),
    case when next_status = 'sent_to_client' then now() else null end
  );

  insert into public.quote_status_events (quote_request_id, from_status, to_status, note, created_by)
  values (target_quote_request_id, old_status, next_status, 'Internal quote review updated', auth.uid());
end;
$$;

create or replace function public.ttaq_get_public_quote_response(
  raw_response_token text,
  public_reference_value text
)
returns table (
  id uuid,
  status public.ttaq_quote_status,
  public_reference text,
  company_name text,
  contact_person text,
  email text,
  phone text,
  collection_address text,
  delivery_address text,
  cargo_type text,
  load_description text,
  stackable boolean,
  load_type public.ttaq_load_type,
  loading_method text,
  offloading_method text,
  goods_value numeric,
  insurance_required boolean,
  collection_date date,
  delivery_date date,
  special_requirements text,
  attachment_note text,
  suggestion_notes text,
  admin_notes text,
  adjusted_price numeric,
  created_at timestamptz,
  quote_items jsonb
)
language sql
security definer
set search_path = public
stable
as $$
  select
    qr.id,
    qr.status,
    qr.public_reference,
    qr.company_name,
    qr.contact_person,
    qr.email,
    qr.phone,
    qr.collection_address,
    qr.delivery_address,
    qr.cargo_type,
    qr.load_description,
    qr.stackable,
    qr.load_type,
    qr.loading_method,
    qr.offloading_method,
    qr.goods_value,
    qr.insurance_required,
    qr.collection_date,
    qr.delivery_date,
    qr.special_requirements,
    qr.attachment_note,
    qr.suggestion_notes,
    null::text as admin_notes,
    qr.adjusted_price,
    qr.created_at,
    coalesce(
      jsonb_agg(to_jsonb(qi) order by qi.created_at) filter (where qi.id is not null),
      '[]'::jsonb
    ) as quote_items
  from public.quote_requests qr
  left join public.quote_items qi on qi.quote_request_id = qr.id
  where qr.status in ('sent_to_client', 'client_accepted', 'client_declined')
    and (
      qr.response_token_hash = public.ttaq_hash_token(raw_response_token)
      or (
        public_reference_value is not null
        and qr.public_reference = public_reference_value
      )
    )
  group by qr.id;
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
begin
  if decision_status not in ('client_accepted', 'client_declined') then
    raise exception 'Invalid quote response';
  end if;

  select id, status
    into target_id, old_status
  from public.quote_requests
  where status = 'sent_to_client'
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

  update public.quote_requests
     set status = decision_status,
         client_responded_at = now()
   where id = target_id;

  insert into public.quote_status_events (quote_request_id, from_status, to_status, note)
  values (target_id, old_status, decision_status, 'Public quote response submitted');

  insert into public.notifications (quote_request_id, recipient_email, notification_type, payload)
  values (
    target_id,
    'admin@timetrucking.co.za',
    'quote_response_placeholder',
    jsonb_build_object('decision', decision_status)
  );
end;
$$;
