create extension if not exists pgcrypto;

create or replace function public.ttaq_record_driver_job_action(
  target_transport_job_id uuid,
  action_type text,
  action_notes text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_status text;
  event_label text;
begin
  if not (
    public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
    or public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  ) then
    raise exception 'Only approved Time Trucking internal users can record driver job actions.';
  end if;

  if action_type not in (
    'pickup_check_in',
    'pickup_confirmed',
    'delivery_check_in',
    'delivery_confirmed',
    'pod_placeholder_uploaded'
  ) then
    raise exception 'Unsupported driver job action: %', action_type;
  end if;

  select job_status
    into current_status
  from public.transport_jobs
  where id = target_transport_job_id;

  if current_status is null then
    raise exception 'Transport job not found: %', target_transport_job_id;
  end if;

  if current_status <> 'active' and action_type <> 'pod_placeholder_uploaded' then
    raise exception 'Driver actions can only be recorded against active jobs.';
  end if;

  event_label := case action_type
    when 'pickup_check_in' then 'Arrived at pickup'
    when 'pickup_confirmed' then 'Pickup confirmed'
    when 'delivery_check_in' then 'Arrived at delivery'
    when 'delivery_confirmed' then 'Delivery confirmed'
    when 'pod_placeholder_uploaded' then 'POD placeholder uploaded'
    else action_type
  end;

  update public.transport_jobs
  set
    actual_pickup_time = case
      when action_type in ('pickup_check_in', 'pickup_confirmed') and actual_pickup_time is null then now()
      else actual_pickup_time
    end,
    actual_delivery_time = case
      when action_type in ('delivery_check_in', 'delivery_confirmed') and actual_delivery_time is null then now()
      else actual_delivery_time
    end,
    job_status = case
      when action_type = 'delivery_confirmed' then 'completed'
      else job_status
    end
  where id = target_transport_job_id;

  insert into public.transport_job_events (
    transport_job_id,
    event_type,
    from_status,
    to_status,
    event_notes,
    event_payload,
    created_by
  )
  values (
    target_transport_job_id,
    action_type,
    current_status,
    case when action_type = 'delivery_confirmed' then 'completed' else current_status end,
    coalesce(nullif(action_notes, ''), event_label),
    jsonb_build_object(
      'source', 'driver_operations_foundation',
      'label', event_label
    ),
    auth.uid()
  );

  if action_type = 'pod_placeholder_uploaded' then
    insert into public.transport_job_documents (
      transport_job_id,
      document_type,
      document_name,
      customer_safe
    )
    values (
      target_transport_job_id,
      'pod_placeholder',
      'Proof of delivery placeholder',
      true
    );
  end if;
end;
$$;
