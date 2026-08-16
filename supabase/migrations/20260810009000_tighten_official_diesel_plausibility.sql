create or replace function public.ttaq_record_diesel_provider_result(
  provider_key_value text,
  provider_status_value text,
  provider_price_per_litre_value numeric default null,
  effective_from_value date default current_date,
  provider_response_value jsonb default '{}'::jsonb,
  error_message_value text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_id uuid;
  provider_record public.pricing_external_providers%rowtype;
  config_record public.pricing_diesel_configuration%rowtype;
  previous_price numeric;
  result_id uuid;
  duplicate_id uuid;
  diesel_grade_value text;
  pricing_basis_value text;
  official_price numeric;
  effective_price numeric;
  adjustment_type_value text;
  adjustment_value numeric;
  publication_date_value date;
begin
  select * into provider_record
  from public.pricing_external_providers
  where provider_key = provider_key_value;

  if provider_record.id is null then
    raise exception 'Pricing provider is not configured: %', provider_key_value;
  end if;

  profile_id := public.ttaq_active_pricing_profile();
  if profile_id is null then
    raise exception 'No active pricing profile configured';
  end if;

  select * into config_record
  from public.pricing_diesel_configuration
  where pricing_profile_id = profile_id;

  diesel_grade_value := coalesce(nullif(provider_response_value->>'diesel_grade', ''), config_record.preferred_diesel_grade);
  pricing_basis_value := coalesce(nullif(provider_response_value->>'pricing_basis', ''), config_record.pricing_basis, 'unconfigured');
  official_price := provider_price_per_litre_value;
  adjustment_type_value := coalesce(nullif(config_record.adjustment_type, ''), 'fixed_r_per_litre');
  adjustment_value := coalesce(config_record.adjustment_value, 0);
  publication_date_value := nullif(provider_response_value->>'publication_date', '')::date;

  if provider_status_value in ('success', 'verified', 'live') then
    if coalesce(official_price, 0) <= 0 then
      raise exception 'Successful diesel provider result requires a positive price';
    end if;
    if official_price < 5 or official_price > 35 then
      raise exception 'Official diesel price outside plausible ZAR/L range: %', official_price;
    end if;
    if diesel_grade_value is null or diesel_grade_value not in ('diesel_500ppm', 'diesel_50ppm') then
      raise exception 'Successful diesel provider result requires an approved diesel grade.';
    end if;
    if pricing_basis_value not in ('unconfigured', 'inland', 'coastal', 'zone', 'depot') then
      raise exception 'Unsupported diesel pricing basis: %', pricing_basis_value;
    end if;
    if coalesce(effective_from_value, current_date) < current_date - interval '70 days' then
      raise exception 'Diesel effective date is too old for a new provider result.';
    end if;
  end if;

  effective_price := case
    when provider_status_value in ('success', 'verified', 'live') and adjustment_type_value = 'percentage'
      then round(official_price * (1 + adjustment_value / 100), 4)
    when provider_status_value in ('success', 'verified', 'live')
      then round(official_price + adjustment_value, 4)
    else null
  end;

  if effective_price is not null and (effective_price <= 0 or effective_price > 35) then
    raise exception 'Effective diesel price outside plausible ZAR/L range: %', effective_price;
  end if;

  select coalesce(effective_diesel_price_per_litre, provider_price_per_litre, admin_override_price_per_litre)
    into previous_price
  from public.diesel_price_integrations
  where pricing_profile_id = profile_id
    and coalesce(effective_diesel_price_per_litre, provider_price_per_litre, admin_override_price_per_litre, 0) between 5 and 35
  order by effective_from desc, created_at desc
  limit 1;

  if provider_status_value in ('success', 'verified', 'live') then
    select id into duplicate_id
    from public.diesel_price_integrations
    where pricing_profile_id = profile_id
      and provider_name = provider_key_value
      and effective_from = coalesce(effective_from_value, current_date)
      and coalesce(diesel_grade, '') = coalesce(diesel_grade_value, '')
      and coalesce(pricing_basis, '') = coalesce(pricing_basis_value, '')
      and coalesce(official_reference_price_per_litre, provider_price_per_litre) = official_price
    order by created_at desc
    limit 1;

    if duplicate_id is not null then
      update public.diesel_price_integrations
         set refreshed_at = now(),
             provider_status = provider_status_value,
             provider_response = coalesce(provider_response, '{}'::jsonb) || coalesce(provider_response_value, '{}'::jsonb),
             raw_source_metadata = coalesce(raw_source_metadata, '{}'::jsonb) || coalesce(provider_response_value->'raw_source_metadata', '{}'::jsonb),
             updated_at = now()
       where id = duplicate_id
       returning id into result_id;
    end if;
  end if;

  if result_id is null then
    insert into public.diesel_price_integrations (
      pricing_profile_id, provider_name, provider_status, provider_id,
      provider_price_per_litre, admin_override_price_per_litre, previous_price_per_litre,
      effective_from, refreshed_at, manual_override_enabled, source_type, source_url,
      freshness_days, next_expected_refresh, is_cached, error_message,
      official_reference_price_per_litre, effective_diesel_price_per_litre, diesel_grade,
      pricing_basis, pricing_zone, depot_location, adjustment_type, adjustment_value,
      adjustment_reason, publication_date, source_document_url, source_document_title,
      raw_source_metadata, validation_status, provider_response
    )
    values (
      profile_id, provider_key_value, provider_status_value, provider_key_value,
      case when provider_status_value in ('success', 'verified', 'live') then official_price else null end,
      null, previous_price, coalesce(effective_from_value, current_date), now(), false,
      case when provider_status_value in ('success', 'verified', 'live') then 'official_reference' else 'provider_failure' end,
      coalesce(nullif(provider_response_value->>'source_url', ''), provider_record.endpoint_url),
      provider_record.freshness_days, coalesce(effective_from_value, current_date) + provider_record.freshness_days,
      provider_status_value not in ('success', 'verified', 'live'), nullif(error_message_value, ''),
      case when provider_status_value in ('success', 'verified', 'live') then official_price else null end,
      effective_price, diesel_grade_value, pricing_basis_value,
      coalesce(nullif(provider_response_value->>'pricing_zone', ''), config_record.pricing_zone),
      coalesce(nullif(provider_response_value->>'depot_location', ''), config_record.depot_location),
      adjustment_type_value, adjustment_value, config_record.adjustment_reason, publication_date_value,
      nullif(provider_response_value->>'source_url', ''), nullif(provider_response_value->>'source_title', ''),
      coalesce(provider_response_value->'raw_source_metadata', '{}'::jsonb),
      case when provider_status_value in ('success', 'verified', 'live') then 'validated' else 'failed' end,
      coalesce(provider_response_value, '{}'::jsonb) || jsonb_build_object(
        'provider_key', provider_key_value,
        'display_source', case when provider_status_value in ('success', 'verified', 'live') then provider_record.provider_name else 'Provider failed; cached/manual hierarchy applies' end,
        'official_reference_price_per_litre', official_price,
        'effective_diesel_price_per_litre', effective_price,
        'adjustment_type', adjustment_type_value,
        'adjustment_value', adjustment_value
      )
    )
    returning id into result_id;
  end if;

  update public.pricing_external_providers
     set provider_status = case when provider_status_value in ('success', 'verified', 'live') then 'configured' else 'failed' end,
         last_success_at = case when provider_status_value in ('success', 'verified', 'live') then now() else last_success_at end,
         last_failure_at = case when provider_status_value in ('success', 'verified', 'live') then last_failure_at else now() end,
         last_error = nullif(error_message_value, '')
   where id = provider_record.id;

  return result_id;
end;
$$;

revoke all on function public.ttaq_record_diesel_provider_result(text, text, numeric, date, jsonb, text) from public;
revoke all on function public.ttaq_record_diesel_provider_result(text, text, numeric, date, jsonb, text) from anon;
revoke all on function public.ttaq_record_diesel_provider_result(text, text, numeric, date, jsonb, text) from authenticated;
grant execute on function public.ttaq_record_diesel_provider_result(text, text, numeric, date, jsonb, text) to service_role;

create or replace function public.ttaq_current_diesel_input(profile_id uuid)
returns table(
  price_per_litre numeric,
  source_label text,
  provider_name text,
  provider_status text,
  effective_from date,
  retrieved_at timestamptz,
  previous_price_per_litre numeric,
  manual_override boolean,
  is_cached boolean,
  requires_review boolean,
  source_payload jsonb
)
language sql
security definer
set search_path = public
stable
as $$
  with config as (
    select * from public.pricing_diesel_configuration c where c.pricing_profile_id = profile_id
  ),
  settings as (
    select greatest(public.ttaq_pricing_setting(profile_id, 'diesel_max_age_days'), 1) as max_age_days
  ),
  active_manual as (
    select
      c.manual_override_price_per_litre as price_per_litre,
      'Manual override'::text as source_label,
      'manual_admin_override'::text as provider_name,
      'manual_override'::text as provider_status,
      coalesce(c.manual_override_starts_at::date, current_date) as effective_from,
      coalesce(c.updated_at, c.created_at) as retrieved_at,
      null::numeric as previous_price_per_litre,
      true as manual_override,
      false as is_cached,
      jsonb_build_object(
        'source_label', 'Manual override',
        'manual_override_reason', c.manual_override_reason,
        'override_started_at', c.manual_override_starts_at,
        'override_expires_at', c.manual_override_expires_at,
        'preferred_diesel_grade', c.preferred_diesel_grade,
        'pricing_basis', c.pricing_basis,
        'pricing_zone', c.pricing_zone,
        'depot_location', c.depot_location
      ) as source_payload
    from config c
    where c.manual_override_enabled
      and c.manual_override_price_per_litre between 5 and 35
      and coalesce(c.manual_override_starts_at, now()) <= now()
      and (c.manual_override_expires_at is null or c.manual_override_expires_at > now())
    limit 1
  ),
  official_value as (
    select
      coalesce(d.effective_diesel_price_per_litre, d.provider_price_per_litre) as price_per_litre,
      case
        when coalesce(d.refreshed_at, d.created_at) < now() - ((select max_age_days from settings)::text || ' days')::interval then 'Cached official value'
        else 'Live official'
      end as source_label,
      d.provider_name, d.provider_status, d.effective_from, coalesce(d.refreshed_at, d.created_at) as retrieved_at,
      d.previous_price_per_litre, false as manual_override,
      coalesce(d.is_cached, false)
        or coalesce(d.refreshed_at, d.created_at) < now() - ((select max_age_days from settings)::text || ' days')::interval as is_cached,
      d.provider_response, d.official_reference_price_per_litre, d.effective_diesel_price_per_litre,
      d.diesel_grade, d.pricing_basis, d.pricing_zone, d.depot_location, d.adjustment_type,
      d.adjustment_value, d.adjustment_reason, d.publication_date, d.source_document_url,
      d.source_document_title, d.validation_status
    from public.diesel_price_integrations d
    left join config c on true
    where d.pricing_profile_id = profile_id
      and d.effective_from <= current_date
      and d.provider_status in ('success', 'verified', 'live')
      and d.provider_price_per_litre between 5 and 35
      and coalesce(d.effective_diesel_price_per_litre, d.provider_price_per_litre) between 5 and 35
      and (c.preferred_diesel_grade is null or d.diesel_grade = c.preferred_diesel_grade)
      and (c.pricing_basis in ('unconfigured', 'zone', 'depot') or d.pricing_basis = c.pricing_basis)
    order by d.effective_from desc, d.created_at desc
    limit 1
  ),
  failure_value as (
    select d.provider_status, d.error_message, coalesce(d.refreshed_at, d.created_at) as retrieved_at, d.provider_response
    from public.diesel_price_integrations d
    where d.pricing_profile_id = profile_id
      and d.provider_status not in ('success', 'verified', 'live')
      and d.provider_name in ('za_dmpr_official_diesel', 'za_dmre_cef_diesel')
    order by d.created_at desc
    limit 1
  ),
  chosen as (
    select * from active_manual
    union all
    select
      o.price_per_litre, o.source_label, o.provider_name, o.provider_status, o.effective_from,
      o.retrieved_at, o.previous_price_per_litre, o.manual_override, o.is_cached,
      jsonb_build_object(
        'source_label', o.source_label,
        'provider_name', o.provider_name,
        'provider_status', o.provider_status,
        'official_reference_price_per_litre', o.official_reference_price_per_litre,
        'effective_diesel_price_per_litre', o.effective_diesel_price_per_litre,
        'diesel_grade', o.diesel_grade,
        'pricing_basis', o.pricing_basis,
        'pricing_zone', o.pricing_zone,
        'depot_location', o.depot_location,
        'adjustment_type', o.adjustment_type,
        'adjustment_value', o.adjustment_value,
        'adjustment_reason', o.adjustment_reason,
        'publication_date', o.publication_date,
        'source_url', o.source_document_url,
        'source_title', o.source_document_title,
        'validation_status', o.validation_status,
        'provider_response', coalesce(o.provider_response, '{}'::jsonb)
      ) as source_payload
    from official_value o
    where not exists (select 1 from active_manual)
    limit 1
  )
  select
    coalesce(chosen.price_per_litre, 0),
    coalesce(chosen.source_label, case when failure_value.provider_status is not null then 'Provider unavailable' else 'Diesel price unavailable - automatic pricing requires review.' end),
    coalesce(chosen.provider_name, 'za_dmpr_official_diesel'),
    coalesce(chosen.provider_status, failure_value.provider_status, 'not_configured'),
    chosen.effective_from,
    coalesce(chosen.retrieved_at, failure_value.retrieved_at),
    chosen.previous_price_per_litre,
    coalesce(chosen.manual_override, false),
    coalesce(chosen.is_cached, false),
    coalesce(chosen.price_per_litre, 0) <= 0
      or coalesce((select preferred_diesel_grade from config), '') not in ('diesel_500ppm', 'diesel_50ppm')
      or coalesce((select pricing_basis from config), 'unconfigured') = 'unconfigured'
      or coalesce(chosen.is_cached, false),
    coalesce(chosen.source_payload, '{}'::jsonb)
      || jsonb_build_object(
        'preferred_diesel_grade', (select preferred_diesel_grade from config),
        'configured_pricing_basis', (select pricing_basis from config),
        'configured_pricing_zone', (select pricing_zone from config),
        'configured_depot_location', (select depot_location from config),
        'configured_adjustment_type', (select adjustment_type from config),
        'configured_adjustment_value', (select adjustment_value from config),
        'last_provider_failure', coalesce(failure_value.provider_response, '{}'::jsonb),
        'last_successfully_checked', chosen.retrieved_at,
        'cache_age_days', case when chosen.retrieved_at is null then null else floor(extract(epoch from (now() - chosen.retrieved_at)) / 86400)::integer end,
        'review_warning', case
          when coalesce(chosen.price_per_litre, 0) <= 0 then 'Diesel price unavailable - automatic pricing requires review.'
          when coalesce((select preferred_diesel_grade from config), '') not in ('diesel_500ppm', 'diesel_50ppm') then 'Preferred diesel grade is not configured.'
          when coalesce((select pricing_basis from config), 'unconfigured') = 'unconfigured' then 'Diesel pricing basis is not configured.'
          when coalesce(chosen.is_cached, false) then 'Cached official value requires review.'
          else null
        end
      )
  from settings
  left join chosen on true
  left join failure_value on true;
$$;
