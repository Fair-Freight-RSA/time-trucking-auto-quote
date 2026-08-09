create extension if not exists pgcrypto;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  (
    'quote-documents',
    'quote-documents',
    false,
    10485760,
    array['application/pdf', 'text/html']
  ),
  (
    'operational-documents',
    'operational-documents',
    false,
    15728640,
    array['application/pdf', 'image/jpeg', 'image/png', 'image/webp']
  )
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Internal users read operational document storage" on storage.objects;
create policy "Internal users read operational document storage"
on storage.objects
for select
using (
  bucket_id = 'operational-documents'
  and (
    public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
    or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
  )
);

drop policy if exists "Owner and manager manage operational document storage" on storage.objects;
create policy "Owner and manager manage operational document storage"
on storage.objects
for all
using (
  bucket_id = 'operational-documents'
  and public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
)
with check (
  bucket_id = 'operational-documents'
  and public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

alter table public.invoices
  add column if not exists pdf_storage_path text,
  add column if not exists pdf_generated_at timestamptz,
  add column if not exists sent_at timestamptz,
  add column if not exists email_sent_to text,
  add column if not exists email_status text not null default 'pending',
  add column if not exists email_error text,
  add column if not exists provider_message_id text;

alter table public.transport_job_documents
  add column if not exists storage_path text,
  add column if not exists content_type text,
  add column if not exists file_size_bytes bigint,
  add column if not exists uploaded_by uuid references public.internal_users(id),
  add column if not exists uploaded_at timestamptz;

alter table public.fuel_slips
  add column if not exists content_type text,
  add column if not exists file_size_bytes bigint,
  add column if not exists uploaded_at timestamptz;

alter table public.email_logs
  add column if not exists entity_type text,
  add column if not exists entity_id uuid,
  add column if not exists requested_at timestamptz not null default now(),
  add column if not exists sent_at timestamptz,
  add column if not exists retry_count integer not null default 0,
  add column if not exists provider_response jsonb not null default '{}'::jsonb;

create index if not exists invoices_pdf_storage_path_idx on public.invoices(pdf_storage_path);
create index if not exists transport_job_documents_storage_path_idx on public.transport_job_documents(storage_path);
create index if not exists email_logs_entity_idx on public.email_logs(entity_type, entity_id, created_at desc);

create or replace function public.ttaq_record_document_uploaded(
  target_entity_type text,
  target_entity_id uuid,
  storage_path_value text,
  document_name_value text,
  content_type_value text default null,
  file_size_bytes_value bigint default null,
  customer_safe_value boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  document_id uuid;
begin
  if not (
    public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
    or public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  ) then
    raise exception 'Only approved Time Trucking internal users can record document uploads.';
  end if;

  if target_entity_type = 'transport_job' then
    insert into public.transport_job_documents (
      transport_job_id,
      document_type,
      document_name,
      pdf_storage_path,
      storage_path,
      content_type,
      file_size_bytes,
      customer_safe,
      uploaded_by,
      uploaded_at
    )
    values (
      target_entity_id,
      'operational_document',
      coalesce(nullif(document_name_value, ''), 'Operational document'),
      nullif(storage_path_value, ''),
      nullif(storage_path_value, ''),
      nullif(content_type_value, ''),
      file_size_bytes_value,
      coalesce(customer_safe_value, false),
      auth.uid(),
      now()
    )
    returning id into document_id;
    return document_id;
  elsif target_entity_type = 'fuel_slip' then
    update public.fuel_slips
       set storage_path = nullif(storage_path_value, ''),
           document_url = null,
           content_type = nullif(content_type_value, ''),
           file_size_bytes = file_size_bytes_value,
           uploaded_at = now(),
           status = case when status = 'placeholder' then 'submitted' else status end
     where id = target_entity_id
     returning id into document_id;

    if document_id is null then
      raise exception 'Fuel slip not found: %', target_entity_id;
    end if;
    return document_id;
  else
    raise exception 'Unsupported document entity type: %', target_entity_type;
  end if;
end;
$$;
