create or replace function public.ttaq_record_route_risk_override(
  target_quote_request_id uuid,
  target_pricing_calculation_id uuid,
  override_risk_category_value text,
  override_risk_amount_value numeric,
  override_reason_value text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_id uuid;
  calculation_record public.pricing_calculations%rowtype;
  override_id uuid;
  risk_snapshot jsonb;
begin
  if not (
    public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules')
    or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
  ) then
    raise exception 'Not authorised to override route risk pricing.';
  end if;

  if coalesce(override_risk_amount_value, -1) < 0 then
    raise exception 'Route risk override amount must be zero or greater.';
  end if;

  if length(trim(coalesce(override_reason_value, ''))) < 5 then
    raise exception 'Route risk override reason is required.';
  end if;

  select id into actor_id
  from public.internal_users
  where id = auth.uid()
    and user_status = 'active'
  limit 1;

  if actor_id is null then
    raise exception 'Active internal user not found for route risk override.';
  end if;

  select * into calculation_record
  from public.pricing_calculations
  where id = target_pricing_calculation_id
    and quote_request_id = target_quote_request_id;

  if calculation_record.id is null then
    raise exception 'Pricing calculation not found for route risk override.';
  end if;

  update public.route_risk_overrides
     set is_active = false
   where quote_request_id = target_quote_request_id
     and is_active;

  risk_snapshot := coalesce(calculation_record.pricing_source_snapshot->'route_risk', '{}'::jsonb);

  insert into public.route_risk_overrides (
    quote_request_id,
    pricing_calculation_id,
    system_risk_category,
    system_risk_amount,
    override_risk_category,
    override_risk_amount,
    override_reason,
    override_payload,
    created_by
  )
  values (
    target_quote_request_id,
    target_pricing_calculation_id,
    risk_snapshot->>'category',
    calculation_record.route_risk_amount,
    nullif(override_risk_category_value, ''),
    override_risk_amount_value,
    trim(override_reason_value),
    jsonb_build_object(
      'system_snapshot', risk_snapshot,
      'resulting_quote_delta', override_risk_amount_value - coalesce(calculation_record.route_risk_amount, 0),
      'source', 'management_override'
    ),
    actor_id
  )
  returning id into override_id;

  insert into public.pricing_calculation_audit_events (quote_request_id, pricing_calculation_id, event_type, event_payload, created_by)
  values (
    target_quote_request_id,
    target_pricing_calculation_id,
    'route_risk_override_recorded',
    jsonb_build_object(
      'override_id', override_id,
      'system_risk_amount', calculation_record.route_risk_amount,
      'override_risk_amount', override_risk_amount_value,
      'override_risk_category', override_risk_category_value,
      'reason', override_reason_value
    ),
    actor_id
  );

  return override_id;
end;
$$;

revoke all on function public.ttaq_record_route_risk_override(uuid, uuid, text, numeric, text) from public;
grant execute on function public.ttaq_record_route_risk_override(uuid, uuid, text, numeric, text) to authenticated;
