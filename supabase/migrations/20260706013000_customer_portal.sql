create extension if not exists pgcrypto;

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
  pod_placeholder_status text
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
    end as pod_placeholder_status
  from target_quote tq
  left join latest_job lj on true
  left join pickup_stop ps on true
  left join delivery_stop ds on true;
$$;
