create extension if not exists pgcrypto;

alter table public.quote_documents
  add column if not exists pdf_url text,
  add column if not exists pdf_storage_path text,
  add column if not exists generated_at timestamptz,
  add column if not exists email_sent_to text,
  add column if not exists email_status text not null default 'pending',
  add column if not exists email_error text;

create index if not exists quote_documents_pdf_storage_path_idx
on public.quote_documents(pdf_storage_path);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'quote-documents',
  'quote-documents',
  false,
  10485760,
  array['application/pdf', 'text/html']
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy "Internal users read quote document storage"
on storage.objects
for select
using (
  bucket_id = 'quote-documents'
  and (
    public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
    or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
  )
);

create policy "Owner and manager manage quote document storage"
on storage.objects
for all
using (
  bucket_id = 'quote-documents'
  and public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
)
with check (
  bucket_id = 'quote-documents'
  and public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create or replace function public.ttaq_mark_quote_document_generated(
  target_quote_document_id uuid,
  pdf_storage_path_value text default null,
  pdf_url_value text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Only approved Time Trucking internal users can mark quote documents generated.';
  end if;

  update public.quote_documents
  set
    pdf_storage_path = coalesce(nullif(pdf_storage_path_value, ''), pdf_storage_path),
    pdf_url = coalesce(nullif(pdf_url_value, ''), pdf_url),
    generated_by = coalesce(generated_by, auth.uid()),
    generated_at = now()
  where id = target_quote_document_id;

  if not found then
    raise exception 'Quote document not found: %', target_quote_document_id;
  end if;

  return target_quote_document_id;
end;
$$;

create or replace function public.ttaq_mark_quote_document_sent(
  target_quote_document_id uuid,
  email_sent_to_value text,
  email_status_value text,
  email_error_value text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Only approved Time Trucking internal users can mark quote documents sent.';
  end if;

  if email_status_value not in ('pending', 'simulated', 'failed', 'sent') then
    raise exception 'Unsupported email status: %', email_status_value;
  end if;

  update public.quote_documents
  set
    sent_at = case when email_status_value in ('simulated', 'sent') then now() else sent_at end,
    email_sent_to = nullif(email_sent_to_value, ''),
    email_status = email_status_value,
    email_error = nullif(email_error_value, '')
  where id = target_quote_document_id;

  if not found then
    raise exception 'Quote document not found: %', target_quote_document_id;
  end if;

  insert into public.quote_customer_events (
    quote_document_id,
    quote_request_id,
    event_type,
    event_payload
  )
  select
    qd.id,
    qd.quote_request_id,
    'quote_email_' || email_status_value,
    jsonb_build_object(
      'email_sent_to', nullif(email_sent_to_value, ''),
      'email_status', email_status_value,
      'email_error', nullif(email_error_value, '')
    )
  from public.quote_documents qd
  where qd.id = target_quote_document_id;

  return target_quote_document_id;
end;
$$;

create or replace function public.ttaq_get_internal_quote_document(
  target_quote_document_id uuid default null,
  target_quote_request_id uuid default null
)
returns table (
  quote_document_id uuid,
  quote_request_id uuid,
  quote_number text,
  public_reference text,
  quote_date date,
  validity_date date,
  version_number integer,
  document_status text,
  final_selling_price numeric,
  vat_amount numeric,
  currency text,
  pdf_url text,
  pdf_storage_path text,
  generated_at timestamptz,
  sent_at timestamptz,
  email_sent_to text,
  email_status text,
  email_error text,
  customer_payload jsonb,
  document_payload jsonb
)
language sql
security definer
set search_path = public
as $$
  select
    qd.id,
    qd.quote_request_id,
    qd.quote_number,
    qd.public_reference,
    qd.quote_date,
    qd.validity_date,
    qd.version_number,
    qd.status,
    qd.final_selling_price,
    qd.vat_amount,
    qd.currency,
    qd.pdf_url,
    qd.pdf_storage_path,
    qd.generated_at,
    qd.sent_at,
    qd.email_sent_to,
    qd.email_status,
    qd.email_error,
    qd.customer_payload,
    qd.document_payload
  from public.quote_documents qd
  where (
      public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
      or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
    )
    and (
      (target_quote_document_id is not null and qd.id = target_quote_document_id)
      or (
        target_quote_document_id is null
        and target_quote_request_id is not null
        and qd.quote_request_id = target_quote_request_id
      )
    )
  order by qd.version_number desc
  limit 1;
$$;

drop function if exists public.ttaq_get_public_quote_document(text, text);

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
  pdf_url text,
  generated_at timestamptz,
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
    qd.pdf_url,
    qd.generated_at,
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
