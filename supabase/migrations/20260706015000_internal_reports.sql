create extension if not exists pgcrypto;

create or replace function public.ttaq_get_internal_reports()
returns table (
  total_rfqs bigint,
  quotes_generated bigint,
  quotes_accepted bigint,
  quotes_declined bigint,
  conversion_rate numeric,
  jobs_scheduled bigint,
  jobs_active bigint,
  jobs_completed bigint,
  jobs_cancelled bigint,
  invoices_generated bigint,
  paid_invoices bigint,
  unpaid_invoices bigint,
  total_quoted_value numeric,
  total_invoiced_value numeric,
  outstanding_amount numeric
)
language sql
security definer
set search_path = public
as $$
  select
    coalesce((select count(*) from public.quote_requests), 0)::bigint as total_rfqs,
    coalesce((select count(distinct quote_request_id) from public.quote_documents), 0)::bigint as quotes_generated,
    coalesce((select count(*) from public.quote_requests where status in ('client_accepted', 'converted_to_load')), 0)::bigint as quotes_accepted,
    coalesce((select count(*) from public.quote_requests where status = 'client_declined'), 0)::bigint as quotes_declined,
    case
      when coalesce((select count(distinct quote_request_id) from public.quote_documents), 0) = 0 then 0
      else round(
        (
          coalesce((select count(*) from public.quote_requests where status in ('client_accepted', 'converted_to_load')), 0)::numeric
          / nullif((select count(distinct quote_request_id) from public.quote_documents)::numeric, 0)
        ) * 100,
        2
      )
    end as conversion_rate,
    coalesce((select count(*) from public.transport_jobs where job_status = 'scheduled'), 0)::bigint as jobs_scheduled,
    coalesce((select count(*) from public.transport_jobs where job_status = 'active'), 0)::bigint as jobs_active,
    coalesce((select count(*) from public.transport_jobs where job_status = 'completed'), 0)::bigint as jobs_completed,
    coalesce((select count(*) from public.transport_jobs where job_status = 'cancelled'), 0)::bigint as jobs_cancelled,
    coalesce((select count(*) from public.invoices), 0)::bigint as invoices_generated,
    coalesce((select count(*) from public.invoices where payment_status = 'paid'), 0)::bigint as paid_invoices,
    coalesce((select count(*) from public.invoices where payment_status in ('unpaid', 'partial', 'overdue')), 0)::bigint as unpaid_invoices,
    coalesce((select sum(final_selling_price) from public.quote_documents), 0)::numeric as total_quoted_value,
    coalesce((select sum(total_amount) from public.invoices), 0)::numeric as total_invoiced_value,
    coalesce((select sum(balance_due) from public.invoices where payment_status <> 'cancelled'), 0)::numeric as outstanding_amount
  where (
    public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
    or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
  );
$$;
