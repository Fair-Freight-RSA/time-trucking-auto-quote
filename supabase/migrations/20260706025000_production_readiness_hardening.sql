create extension if not exists pgcrypto;

create or replace function public.ttaq_add_check_constraint_if_missing(
  target_table regclass,
  constraint_name text,
  constraint_sql text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = constraint_name
      and conrelid = target_table
  ) then
    execute format('alter table %s add constraint %I check (%s) not valid', target_table, constraint_name, constraint_sql);
  end if;
end;
$$;

select public.ttaq_add_check_constraint_if_missing('public.route_estimates', 'route_estimates_non_negative_distance_check', 'total_distance_km >= 0 and total_duration_hours >= 0 and coalesce(manual_distance_km, 0) >= 0 and coalesce(manual_duration_hours, 0) >= 0');
select public.ttaq_add_check_constraint_if_missing('public.route_estimate_stops', 'route_estimate_stops_order_positive_check', 'stop_order > 0');
select public.ttaq_add_check_constraint_if_missing('public.quote_stops', 'quote_stops_order_positive_check', 'stop_order > 0');
select public.ttaq_add_check_constraint_if_missing('public.transport_job_stops', 'transport_job_stops_order_positive_check', 'stop_order > 0');
select public.ttaq_add_check_constraint_if_missing('public.transport_jobs', 'transport_jobs_status_check', 'job_status in (''draft'', ''scheduled'', ''active'', ''completed'', ''cancelled'', ''pending_assignment'')');
select public.ttaq_add_check_constraint_if_missing('public.invoices', 'invoices_amounts_non_negative_check', 'subtotal >= 0 and vat_amount >= 0 and total_amount >= 0 and amount_paid >= 0 and balance_due >= 0');
select public.ttaq_add_check_constraint_if_missing('public.invoices', 'invoices_payment_status_check', 'payment_status in (''unpaid'', ''partial'', ''paid'', ''overdue'', ''cancelled'')');
select public.ttaq_add_check_constraint_if_missing('public.invoices', 'invoices_invoice_status_check', 'invoice_status in (''draft'', ''issued'', ''sent'', ''cancelled'', ''paid'')');
select public.ttaq_add_check_constraint_if_missing('public.invoices', 'invoices_vat_not_more_than_total_check', 'vat_amount <= total_amount');
select public.ttaq_add_check_constraint_if_missing('public.invoice_line_items', 'invoice_line_items_amounts_non_negative_check', 'quantity >= 0 and unit_price >= 0 and vat_amount >= 0 and line_total >= 0');
select public.ttaq_add_check_constraint_if_missing('public.invoice_line_items', 'invoice_line_items_order_positive_check', 'line_order > 0');
select public.ttaq_add_check_constraint_if_missing('public.invoice_payments', 'invoice_payments_amount_non_negative_check', 'amount >= 0');
select public.ttaq_add_check_constraint_if_missing('public.transport_job_documents', 'transport_job_documents_storage_path_safe_check', '(storage_path is null or (storage_path !~ ''(^/|\\.\\.)'')) and (pdf_storage_path is null or (pdf_storage_path !~ ''(^/|\\.\\.)''))');
select public.ttaq_add_check_constraint_if_missing('public.quote_documents', 'quote_documents_pdf_path_safe_check', 'pdf_storage_path is null or (pdf_storage_path !~ ''(^/|\\.\\.)'')');

create index if not exists quote_requests_status_created_idx
on public.quote_requests(status, created_at desc);

create index if not exists transport_jobs_status_updated_idx
on public.transport_jobs(job_status, updated_at desc);

create index if not exists invoices_payment_status_due_idx
on public.invoices(payment_status, due_date);

create index if not exists email_logs_entity_status_idx
on public.email_logs(entity_type, entity_id, status, created_at desc);

create index if not exists quote_stops_request_order_idx
on public.quote_stops(quote_request_id, stop_order);

create index if not exists route_estimate_stops_route_order_idx
on public.route_estimate_stops(route_estimate_id, stop_order);

drop function public.ttaq_add_check_constraint_if_missing(regclass, text, text);
