create extension if not exists pgcrypto;

create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  transport_job_id uuid not null unique references public.transport_jobs(id) on delete restrict,
  quote_request_id uuid references public.quote_requests(id) on delete set null,
  quote_document_id uuid references public.quote_documents(id) on delete set null,
  invoice_number text not null unique,
  invoice_status text not null default 'draft',
  payment_status text not null default 'unpaid',
  company_name text not null,
  contact_person text,
  email text,
  invoice_date date not null default current_date,
  due_date date,
  subtotal numeric(14, 2) not null default 0,
  vat_amount numeric(14, 2) not null default 0,
  total_amount numeric(14, 2) not null default 0,
  amount_paid numeric(14, 2) not null default 0,
  balance_due numeric(14, 2) not null default 0,
  currency text not null default 'ZAR',
  customer_payload jsonb not null default '{}'::jsonb,
  internal_notes text,
  created_by uuid references public.internal_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.invoice_line_items (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  line_order integer not null default 1,
  line_type text not null default 'transport',
  description text not null,
  quantity numeric(14, 2) not null default 1,
  unit_price numeric(14, 2) not null default 0,
  vat_amount numeric(14, 2) not null default 0,
  line_total numeric(14, 2) not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.invoice_payments (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  payment_status text not null default 'placeholder',
  payment_method text,
  payment_reference text,
  amount numeric(14, 2) not null default 0,
  payment_date date,
  notes text,
  recorded_by uuid references public.internal_users(id),
  created_at timestamptz not null default now()
);

drop trigger if exists ttaq_invoices_touch_updated_at on public.invoices;
create trigger ttaq_invoices_touch_updated_at
before update on public.invoices
for each row execute function public.ttaq_touch_updated_at();

create index if not exists invoices_transport_job_id_idx
on public.invoices(transport_job_id);

create index if not exists invoices_payment_status_idx
on public.invoices(payment_status);

create index if not exists invoice_line_items_invoice_id_idx
on public.invoice_line_items(invoice_id, line_order);

create index if not exists invoice_payments_invoice_id_idx
on public.invoice_payments(invoice_id, created_at desc);

alter table public.invoices enable row level security;
alter table public.invoice_line_items enable row level security;
alter table public.invoice_payments enable row level security;

create policy "Internal users read invoices"
on public.invoices
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create policy "Owner and manager manage invoices"
on public.invoices
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read invoice line items"
on public.invoice_line_items
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create policy "Owner and manager manage invoice line items"
on public.invoice_line_items
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read invoice payments"
on public.invoice_payments
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create policy "Owner and manager manage invoice payments"
on public.invoice_payments
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create or replace function public.ttaq_generate_invoice_from_job(
  target_transport_job_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  job_record public.transport_jobs%rowtype;
  quote_doc public.quote_documents%rowtype;
  existing_invoice_id uuid;
  invoice_id uuid;
  invoice_number_value text;
  subtotal_value numeric(14, 2);
  vat_value numeric(14, 2);
  total_value numeric(14, 2);
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Only approved Time Trucking internal users can generate invoices.';
  end if;

  select id
    into existing_invoice_id
  from public.invoices
  where transport_job_id = target_transport_job_id;

  if existing_invoice_id is not null then
    return existing_invoice_id;
  end if;

  select *
    into job_record
  from public.transport_jobs
  where id = target_transport_job_id;

  if job_record.id is null then
    raise exception 'Transport job not found: %', target_transport_job_id;
  end if;

  if job_record.job_status not in ('completed', 'active') then
    raise exception 'Invoices can only be generated for active or completed jobs.';
  end if;

  select *
    into quote_doc
  from public.quote_documents
  where id = job_record.quote_document_id
  order by version_number desc
  limit 1;

  if quote_doc.id is null then
    select *
      into quote_doc
    from public.quote_documents
    where quote_request_id = job_record.quote_request_id
    order by version_number desc
    limit 1;
  end if;

  total_value := coalesce(quote_doc.final_selling_price, 0);
  vat_value := coalesce(quote_doc.vat_amount, 0);
  subtotal_value := greatest(total_value - vat_value, 0);
  invoice_number_value := 'INV-' || job_record.job_number;

  insert into public.invoices (
    transport_job_id,
    quote_request_id,
    quote_document_id,
    invoice_number,
    invoice_status,
    payment_status,
    company_name,
    contact_person,
    email,
    invoice_date,
    due_date,
    subtotal,
    vat_amount,
    total_amount,
    amount_paid,
    balance_due,
    currency,
    customer_payload,
    created_by
  )
  values (
    job_record.id,
    job_record.quote_request_id,
    quote_doc.id,
    invoice_number_value,
    'issued',
    'unpaid',
    job_record.company_name,
    job_record.contact_person,
    job_record.email,
    current_date,
    current_date + 7,
    subtotal_value,
    vat_value,
    total_value,
    0,
    total_value,
    coalesce(quote_doc.currency, 'ZAR'),
    jsonb_build_object(
      'invoice_number', invoice_number_value,
      'job_number', job_record.job_number,
      'public_reference', job_record.public_reference,
      'company_name', job_record.company_name,
      'invoice_date', current_date,
      'due_date', current_date + 7,
      'total_amount', total_value,
      'currency', coalesce(quote_doc.currency, 'ZAR')
    ),
    auth.uid()
  )
  returning id into invoice_id;

  insert into public.invoice_line_items (
    invoice_id,
    line_order,
    line_type,
    description,
    quantity,
    unit_price,
    vat_amount,
    line_total
  )
  values (
    invoice_id,
    1,
    'transport',
    'Transport service for job ' || job_record.job_number,
    1,
    subtotal_value,
    vat_value,
    total_value
  );

  insert into public.invoice_payments (
    invoice_id,
    payment_status,
    notes,
    recorded_by
  )
  values (
    invoice_id,
    'placeholder',
    'Payment tracking placeholder created with invoice.',
    auth.uid()
  );

  insert into public.transport_job_events (
    transport_job_id,
    event_type,
    event_notes,
    event_payload,
    created_by
  )
  values (
    job_record.id,
    'invoice_generated',
    'Invoice generated from completed/accepted job.',
    jsonb_build_object('invoice_id', invoice_id, 'invoice_number', invoice_number_value),
    auth.uid()
  );

  return invoice_id;
end;
$$;

create or replace function public.ttaq_get_internal_invoice(
  target_invoice_id uuid
)
returns table (
  id uuid,
  transport_job_id uuid,
  quote_request_id uuid,
  quote_document_id uuid,
  invoice_number text,
  invoice_status text,
  payment_status text,
  company_name text,
  contact_person text,
  email text,
  invoice_date date,
  due_date date,
  subtotal numeric,
  vat_amount numeric,
  total_amount numeric,
  amount_paid numeric,
  balance_due numeric,
  currency text,
  customer_payload jsonb,
  internal_notes text,
  line_items jsonb,
  payments jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    inv.id,
    inv.transport_job_id,
    inv.quote_request_id,
    inv.quote_document_id,
    inv.invoice_number,
    inv.invoice_status,
    inv.payment_status,
    inv.company_name,
    inv.contact_person,
    inv.email,
    inv.invoice_date,
    inv.due_date,
    inv.subtotal,
    inv.vat_amount,
    inv.total_amount,
    inv.amount_paid,
    inv.balance_due,
    inv.currency,
    inv.customer_payload,
    inv.internal_notes,
    coalesce((
      select jsonb_agg(to_jsonb(ili) order by ili.line_order asc)
      from public.invoice_line_items ili
      where ili.invoice_id = inv.id
    ), '[]'::jsonb) as line_items,
    coalesce((
      select jsonb_agg(to_jsonb(ip) order by ip.created_at desc)
      from public.invoice_payments ip
      where ip.invoice_id = inv.id
    ), '[]'::jsonb) as payments,
    inv.created_at,
    inv.updated_at
  from public.invoices inv
  where inv.id = target_invoice_id
    and (
      public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
      or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
    );
$$;

create or replace function public.ttaq_list_internal_invoices()
returns table (
  id uuid,
  transport_job_id uuid,
  invoice_number text,
  invoice_status text,
  payment_status text,
  company_name text,
  invoice_date date,
  due_date date,
  total_amount numeric,
  amount_paid numeric,
  balance_due numeric,
  currency text,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    inv.id,
    inv.transport_job_id,
    inv.invoice_number,
    inv.invoice_status,
    inv.payment_status,
    inv.company_name,
    inv.invoice_date,
    inv.due_date,
    inv.total_amount,
    inv.amount_paid,
    inv.balance_due,
    inv.currency,
    inv.created_at
  from public.invoices inv
  where (
    public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
    or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
  )
  order by inv.created_at desc;
$$;

create or replace function public.ttaq_update_invoice_payment_status(
  target_invoice_id uuid,
  payment_status_value text,
  amount_paid_value numeric default null,
  payment_reference_value text default null,
  notes_value text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  invoice_total numeric(14, 2);
  paid_value numeric(14, 2);
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs') then
    raise exception 'Only approved Time Trucking internal users can update invoice payment status.';
  end if;

  if payment_status_value not in ('unpaid', 'partial', 'paid', 'overdue', 'cancelled') then
    raise exception 'Unsupported payment status: %', payment_status_value;
  end if;

  select total_amount
    into invoice_total
  from public.invoices
  where id = target_invoice_id;

  if invoice_total is null then
    raise exception 'Invoice not found: %', target_invoice_id;
  end if;

  paid_value := coalesce(amount_paid_value, case when payment_status_value = 'paid' then invoice_total else 0 end);

  update public.invoices
  set
    payment_status = payment_status_value,
    amount_paid = paid_value,
    balance_due = greatest(invoice_total - paid_value, 0),
    invoice_status = case when payment_status_value = 'cancelled' then 'cancelled' else invoice_status end
  where id = target_invoice_id;

  insert into public.invoice_payments (
    invoice_id,
    payment_status,
    payment_reference,
    amount,
    payment_date,
    notes,
    recorded_by
  )
  values (
    target_invoice_id,
    payment_status_value,
    nullif(payment_reference_value, ''),
    paid_value,
    current_date,
    nullif(notes_value, ''),
    auth.uid()
  );
end;
$$;

drop function if exists public.ttaq_get_customer_portal(text, text);

create or replace function public.ttaq_get_customer_portal(
  raw_response_token text,
  public_reference_value text
)
returns table (
  quote_request_id uuid,
  public_reference text,
  quote_status public.ttaq_quote_status,
  company_name text,
  contact_person text,
  accepted_at timestamptz,
  declined_at timestamptz,
  quote_documents jsonb,
  job_status text,
  pickup_summary jsonb,
  delivery_summary jsonb,
  planned_pickup_time timestamptz,
  planned_delivery_time timestamptz,
  pod_placeholder_status text,
  invoice_status text,
  payment_status text
)
language sql
security definer
set search_path = public
as $$
  with target_quote as (
    select qr.*
    from public.quote_requests qr
    where qr.status in ('sent_to_client', 'client_accepted', 'client_declined', 'converted_to_load')
      and (
        qr.response_token_hash = public.ttaq_hash_token(raw_response_token)
        or (
          public_reference_value is not null
          and qr.public_reference = public_reference_value
        )
      )
    limit 1
  ),
  latest_job as (
    select tj.*
    from public.transport_jobs tj
    join target_quote tq on tq.id = tj.quote_request_id
    order by tj.created_at desc
    limit 1
  ),
  latest_invoice as (
    select inv.*
    from public.invoices inv
    join latest_job lj on lj.id = inv.transport_job_id
    order by inv.created_at desc
    limit 1
  ),
  pickup_stop as (
    select tjs.*
    from public.transport_job_stops tjs
    join latest_job lj on lj.id = tjs.transport_job_id
    where tjs.stop_type in ('collection', 'pickup')
    order by tjs.stop_order asc
    limit 1
  ),
  delivery_stop as (
    select tjs.*
    from public.transport_job_stops tjs
    join latest_job lj on lj.id = tjs.transport_job_id
    where tjs.stop_type = 'delivery'
    order by tjs.stop_order desc
    limit 1
  )
  select
    tq.id,
    tq.public_reference,
    tq.status,
    tq.company_name,
    tq.contact_person,
    (
      select max(qse.created_at)
      from public.quote_status_events qse
      where qse.quote_request_id = tq.id
        and qse.to_status in ('client_accepted', 'converted_to_load')
    ) as accepted_at,
    (
      select max(qse.created_at)
      from public.quote_status_events qse
      where qse.quote_request_id = tq.id
        and qse.to_status = 'client_declined'
    ) as declined_at,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'quote_document_id', qd.id,
        'quote_number', qd.quote_number,
        'quote_date', qd.quote_date,
        'validity_date', qd.validity_date,
        'version_number', qd.version_number,
        'pdf_url', qd.pdf_url,
        'generated_at', qd.generated_at
      ) order by qd.version_number desc)
      from public.quote_documents qd
      where qd.quote_request_id = tq.id
    ), '[]'::jsonb) as quote_documents,
    lj.job_status,
    case
      when ps.id is null then null
      else jsonb_build_object(
        'stop_type', ps.stop_type,
        'address', ps.address,
        'date_time_window', ps.date_time_window
      )
    end as pickup_summary,
    case
      when ds.id is null then null
      else jsonb_build_object(
        'stop_type', ds.stop_type,
        'address', ds.address,
        'date_time_window', ds.date_time_window
      )
    end as delivery_summary,
    lj.planned_pickup_time,
    lj.planned_delivery_time,
    case
      when exists (
        select 1
        from public.transport_job_documents tjd
        where tjd.transport_job_id = lj.id
          and tjd.document_type = 'pod_placeholder'
      ) then 'available'
      when exists (
        select 1
        from public.transport_job_events tje
        where tje.transport_job_id = lj.id
          and tje.event_type = 'delivery_confirmed'
      ) then 'pending_upload'
      else 'not_available'
    end as pod_placeholder_status,
    li.invoice_status,
    li.payment_status
  from target_quote tq
  left join latest_job lj on true
  left join latest_invoice li on true
  left join pickup_stop ps on true
  left join delivery_stop ds on true;
$$;
