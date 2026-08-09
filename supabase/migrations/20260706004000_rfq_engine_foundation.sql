create extension if not exists pgcrypto;

alter type public.ttaq_quote_status add value if not exists 'rfq_submitted' after 'draft';

do $$
begin
  if not exists (select 1 from pg_type where typname = 'ttaq_stop_type' and typnamespace = 'public'::regnamespace) then
    create type public.ttaq_stop_type as enum ('collection', 'delivery', 'warehouse', 'border', 'other');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'ttaq_cargo_category' and typnamespace = 'public'::regnamespace) then
    create type public.ttaq_cargo_category as enum ('general_freight', 'machinery', 'dangerous_goods', 'refrigerated', 'other');
  end if;
end $$;

alter table public.quote_requests
  add column if not exists draft_saved_at timestamptz;

alter table public.quote_items
  add column if not exists client_item_key text,
  add column if not exists cargo_category public.ttaq_cargo_category not null default 'general_freight',
  add column if not exists stackable boolean not null default false,
  add column if not exists fragile boolean not null default false,
  add column if not exists dangerous_goods boolean not null default false,
  add column if not exists temperature_controlled boolean not null default false,
  add column if not exists cargo_value numeric(14, 2),
  add column if not exists notes text;

create table if not exists public.quote_stops (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  stop_order integer not null,
  stop_type public.ttaq_stop_type not null,
  address text not null,
  contact_name text,
  contact_phone text,
  date_time_window text,
  loading_method text,
  offloading_method text,
  notes text,
  created_at timestamptz not null default now(),
  unique (quote_request_id, stop_order)
);

create table if not exists public.rfq_dynamic_answers (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  cargo_item_id uuid references public.quote_items(id) on delete cascade,
  answer_group text not null,
  question_key text not null,
  answer_value text,
  created_at timestamptz not null default now()
);

alter table public.quote_stops enable row level security;
alter table public.rfq_dynamic_answers enable row level security;

create policy "Internal users read allowed quote stops"
on public.quote_stops
for select
using (
  exists (
    select 1
    from public.quote_requests qr
    where qr.id = quote_stops.quote_request_id
      and (
        public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
        or qr.assigned_internal_user_id = auth.uid()
        or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
      )
  )
);

create policy "Owner and manager manage quote stops"
on public.quote_stops
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read dynamic RFQ answers"
on public.rfq_dynamic_answers
for select
using (
  exists (
    select 1
    from public.quote_requests qr
    where qr.id = rfq_dynamic_answers.quote_request_id
      and (
        public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
        or qr.assigned_internal_user_id = auth.uid()
        or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
      )
  )
);

create policy "Owner and manager manage dynamic RFQ answers"
on public.rfq_dynamic_answers
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create index if not exists ttaq_quote_stops_quote_request_id_idx on public.quote_stops(quote_request_id);
create index if not exists ttaq_quote_items_client_item_key_idx on public.quote_items(quote_request_id, client_item_key);
create index if not exists ttaq_dynamic_answers_quote_request_id_idx on public.rfq_dynamic_answers(quote_request_id);

create or replace function public.ttaq_submit_public_rfq(
  raw_rfq_token text,
  raw_response_token text,
  payload jsonb,
  is_final boolean default true
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
  next_status public.ttaq_quote_status;
  item_record jsonb;
  stop_record jsonb;
  inserted_item_id uuid;
  inserted_client_item_key text;
begin
  if raw_response_token is null or length(raw_response_token) = 0 then
    raise exception 'Missing quote response token';
  end if;

  next_status := case when is_final then 'admin_review'::public.ttaq_quote_status else 'draft'::public.ttaq_quote_status end;

  select id, status
    into existing_request_id, old_status
  from public.quote_requests
  where secure_token_hash = public.ttaq_hash_token(raw_rfq_token)
    and status in ('draft', 'client_submitted', 'admin_review')
    and (expires_at is null or expires_at > now())
  limit 1;

  if existing_request_id is null and raw_rfq_token is not null then
    select id, status
      into existing_request_id, old_status
    from public.quote_requests
    where response_token_hash = public.ttaq_hash_token(raw_response_token)
    limit 1;
  end if;

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
      secure_token_hash,
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
      draft_saved_at,
      submitted_at
    )
    values (
      client_record_id,
      contact_record_id,
      public.ttaq_hash_token(raw_rfq_token),
      next_status,
      new_reference,
      public.ttaq_hash_token(raw_response_token),
      payload->>'company_name',
      payload->>'contact_person',
      payload->>'email',
      payload->>'phone',
      coalesce(payload->>'collection_address', payload #>> '{stops,0,address}', 'Pending'),
      coalesce(payload->>'delivery_address', payload #>> '{stops,1,address}', 'Pending'),
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
      case when is_final then null else now() end,
      case when is_final then now() else null end
    )
    returning id into target_quote_request_id;
    old_status := 'draft';
  else
    update public.quote_requests
       set client_id = client_record_id,
           client_contact_id = contact_record_id,
           status = next_status,
           public_reference = coalesce(public.quote_requests.public_reference, new_reference),
           response_token_hash = public.ttaq_hash_token(raw_response_token),
           company_name = payload->>'company_name',
           contact_person = payload->>'contact_person',
           email = payload->>'email',
           phone = payload->>'phone',
           collection_address = coalesce(payload->>'collection_address', payload #>> '{stops,0,address}', 'Pending'),
           delivery_address = coalesce(payload->>'delivery_address', payload #>> '{stops,1,address}', 'Pending'),
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
           draft_saved_at = case when is_final then draft_saved_at else now() end,
           submitted_at = case when is_final then now() else submitted_at end
     where id = existing_request_id
     returning id, public.quote_requests.public_reference into target_quote_request_id, new_reference;
  end if;

  delete from public.rfq_dynamic_answers where rfq_dynamic_answers.quote_request_id = target_quote_request_id;
  delete from public.quote_items where quote_items.quote_request_id = target_quote_request_id;
  delete from public.quote_stops where quote_stops.quote_request_id = target_quote_request_id;

  for stop_record in select * from jsonb_array_elements(coalesce(payload->'stops', '[]'::jsonb))
  loop
    insert into public.quote_stops (
      quote_request_id,
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
    values (
      target_quote_request_id,
      coalesce(
        nullif(stop_record->>'stop_order', '')::integer,
        nullif(stop_record->>'sequence_number', '')::integer,
        1
      ),
      coalesce(nullif(stop_record->>'stop_type', ''), 'other')::public.ttaq_stop_type,
      coalesce(stop_record->>'address', 'Pending'),
      stop_record->>'contact_name',
      stop_record->>'contact_phone',
      stop_record->>'date_time_window',
      stop_record->>'loading_method',
      stop_record->>'offloading_method',
      stop_record->>'notes'
    );
  end loop;

  for item_record in select * from jsonb_array_elements(coalesce(
    payload->'cargo_items',
    payload->'items',
    '[]'::jsonb
  ))
  loop
    inserted_client_item_key := coalesce(item_record->>'client_item_key', gen_random_uuid()::text);

    insert into public.quote_items (
      quote_request_id,
      client_item_key,
      description,
      cargo_category,
      quantity,
      length_m,
      width_m,
      height_m,
      weight_kg,
      stackable,
      fragile,
      dangerous_goods,
      temperature_controlled,
      cargo_value,
      notes
    )
    values (
      target_quote_request_id,
      inserted_client_item_key,
      item_record->>'description',
      coalesce(nullif(item_record->>'cargo_category', ''), 'general_freight')::public.ttaq_cargo_category,
      coalesce((item_record->>'quantity')::integer, 1),
      nullif(item_record->>'length_m', '')::numeric,
      nullif(item_record->>'width_m', '')::numeric,
      nullif(item_record->>'height_m', '')::numeric,
      nullif(item_record->>'weight_kg', '')::numeric,
      coalesce((item_record->>'stackable')::boolean, false),
      coalesce((item_record->>'fragile')::boolean, false),
      coalesce((item_record->>'dangerous_goods')::boolean, false),
      coalesce((item_record->>'temperature_controlled')::boolean, false),
      nullif(item_record->>'cargo_value', '')::numeric,
      item_record->>'notes'
    )
    returning id into inserted_item_id;

    insert into public.rfq_dynamic_answers (
      quote_request_id,
      cargo_item_id,
      answer_group,
      question_key,
      answer_value
    )
    select
      target_quote_request_id,
      inserted_item_id,
      dynamic_answer_record->>'answer_group',
      dynamic_answer_record->>'question_key',
      dynamic_answer_record->>'answer_value'
    from jsonb_array_elements(
      case
        when jsonb_typeof(coalesce(payload->'dynamic_answers', '[]'::jsonb)) = 'array'
          then coalesce(payload->'dynamic_answers', '[]'::jsonb)
        else '[]'::jsonb
      end
    ) dynamic_answer_record
    where dynamic_answer_record->>'client_item_key' = inserted_client_item_key;
  end loop;

  if jsonb_typeof(payload->'dynamic_answers') = 'object' then
    insert into public.rfq_dynamic_answers (
      quote_request_id,
      cargo_item_id,
      answer_group,
      question_key,
      answer_value
    )
    select
      target_quote_request_id,
      null,
      'legacy_object',
      key,
      case
        when jsonb_typeof(value) = 'string' then value #>> '{}'
        else value::text
      end
    from jsonb_each(payload->'dynamic_answers')
    where value is not null;
  end if;

  if not exists (select 1 from public.quote_items where quote_items.quote_request_id = target_quote_request_id) then
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
  end if;

  insert into public.quote_status_events (quote_request_id, from_status, to_status, note)
  values (
    target_quote_request_id,
    old_status,
    next_status,
    case when is_final then 'Public RFQ submitted' else 'Public RFQ draft saved' end
  );

  if is_final then
    insert into public.notifications (quote_request_id, recipient_email, notification_type, payload)
    values (
      target_quote_request_id,
      'admin@timetrucking.co.za',
      'rfq_submitted_placeholder',
      jsonb_build_object('public_reference', new_reference)
    );
  end if;

  quote_request_id := target_quote_request_id;
  public_reference := new_reference;
  response_token := raw_response_token;
  return next;
end;
$$;

drop function if exists public.ttaq_get_public_quote_response(text, text);

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
  quote_items jsonb,
  quote_stops jsonb,
  rfq_dynamic_answers jsonb
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
      (select jsonb_agg(to_jsonb(qi) order by qi.created_at) from public.quote_items qi where qi.quote_request_id = qr.id),
      '[]'::jsonb
    ) as quote_items,
    coalesce(
      (select jsonb_agg(to_jsonb(qs) order by qs.stop_order) from public.quote_stops qs where qs.quote_request_id = qr.id),
      '[]'::jsonb
    ) as quote_stops,
    coalesce(
      (select jsonb_agg(to_jsonb(ra) order by ra.created_at) from public.rfq_dynamic_answers ra where ra.quote_request_id = qr.id),
      '[]'::jsonb
    ) as rfq_dynamic_answers
  from public.quote_requests qr
  where qr.status in ('sent_to_client', 'client_accepted', 'client_declined')
    and (
      qr.response_token_hash = public.ttaq_hash_token(raw_response_token)
      or (
        public_reference_value is not null
        and qr.public_reference = public_reference_value
      )
    );
$$;
