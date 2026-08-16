alter table public.pricing_external_providers
  add column if not exists coverage_status text not null default 'needs_review',
  add column if not exists active_plaza_count integer not null default 0,
  add column if not exists coverage_notes text,
  add constraint pricing_external_providers_coverage_status_check
    check (coverage_status in ('complete', 'partial', 'unavailable', 'needs_review'));

alter table public.standard_equipment_profiles
  add column if not exists suggested_toll_class integer,
  add column if not exists suggested_toll_class_reason text,
  add column if not exists toll_class_review_required boolean not null default true,
  add constraint standard_equipment_profiles_suggested_toll_class_check
    check (suggested_toll_class is null or suggested_toll_class between 1 and 4);

update public.standard_equipment_profiles
   set suggested_toll_class = case
         when vehicle_class = 'small' then 1
         when vehicle_class = 'rigid' and coalesce(payload_capacity_kg, 0) <= 8000 then 2
         when vehicle_class in ('articulated', 'superlink') then 4
         when specialist_abnormal then 4
         else null
       end,
       suggested_toll_class_reason = case
         when vehicle_class = 'small' then 'Suggested from configured small/light vehicle profile; Henning must confirm before automatic toll pricing.'
         when vehicle_class = 'rigid' and coalesce(payload_capacity_kg, 0) <= 8000 then 'Suggested as Class 2 medium heavy vehicle from configured rigid profile; axle count/height still require Time Trucking confirmation.'
         when vehicle_class in ('articulated', 'superlink') then 'Suggested as Class 4 extra-large heavy vehicle from articulated/superlink profile; Henning must confirm actual axle configuration.'
         when specialist_abnormal then 'Suggested as Class 4 for specialist abnormal/heavy configuration; Henning must confirm actual axle configuration.'
         else 'Needs confirmation because configured equipment data is insufficient for reliable toll classification.'
       end,
       toll_class_review_required = toll_class is null or toll_class_source = 'unconfigured'
 where suggested_toll_class is null
    or suggested_toll_class_reason is null;

update public.pricing_external_providers
   set coverage_status = case provider_key
         when 'za_bakwena_official_tolls' then 'complete'
         when 'za_sanral_official_tolls' then 'partial'
         when 'za_trac_n4_official_tolls' then 'partial'
         when 'za_n3tc_official_tolls' then 'partial'
         else coverage_status
       end,
       provider_status = case provider_key
         when 'za_bakwena_official_tolls' then 'complete'
         when 'za_sanral_official_tolls' then 'partial'
         when 'za_trac_n4_official_tolls' then 'partial'
         when 'za_n3tc_official_tolls' then 'partial'
         else provider_status
       end,
       active_plaza_count = coalesce((
         select count(*)
         from public.toll_plazas p
         join public.toll_tariffs t on t.toll_plaza_id = p.id
         where p.operator_key = pricing_external_providers.provider_key
           and p.is_active
           and t.tariff_status in ('active', 'future')
           and t.effective_from <= current_date
           and (t.effective_to is null or t.effective_to >= current_date)
       ), 0),
       coverage_notes = case provider_key
         when 'za_bakwena_official_tolls' then 'Complete for seeded Bakwena N1/N4 official 2026 tariff rows and operator-coordinate-backed route matching.'
         when 'za_sanral_official_tolls' then 'Partial: official SANRAL 2026 tariff source and plaza catalogue identified, but automatic charging remains disabled until reliable plaza coordinates are loaded.'
         when 'za_trac_n4_official_tolls' then 'Partial: TRAC/N4 official 2026 tariff source identified, but automatic charging remains disabled until reliable plaza coordinates are loaded.'
         when 'za_n3tc_official_tolls' then 'Partial: N3TC official 2026 tariff table/source identified, but automatic charging remains disabled until reliable plaza coordinates are loaded.'
         else coverage_notes
       end
 where provider_category = 'toll';

drop function if exists public.ttaq_toll_provider_status();

create function public.ttaq_toll_provider_status()
returns table (
  provider_key text,
  provider_name text,
  provider_status text,
  coverage_status text,
  active_plaza_count integer,
  last_check_at timestamptz,
  last_success_at timestamptz,
  last_failure_at timestamptz,
  last_error text,
  next_expected_check_at timestamptz,
  last_publication_effective_date date,
  last_publication_title text,
  scheduler_status text,
  source_url text,
  coverage_notes text
)
language sql
security definer
set search_path = public
as $$
  select p.provider_key, p.provider_name, p.provider_status, p.coverage_status,
         coalesce((
           select count(*)::integer
           from public.toll_plazas plaza
           join public.toll_tariffs tariff on tariff.toll_plaza_id = plaza.id
           where plaza.operator_key = p.provider_key
             and plaza.is_active
             and tariff.tariff_status in ('active', 'future')
             and tariff.effective_from <= current_date
             and (tariff.effective_to is null or tariff.effective_to >= current_date)
         ), p.active_plaza_count, 0) as active_plaza_count,
         p.last_check_at, p.last_success_at, p.last_failure_at, p.last_error,
         p.next_expected_check_at, p.last_publication_effective_date, p.last_publication_title,
         p.scheduler_status, p.endpoint_url as source_url, p.coverage_notes
  from public.pricing_external_providers p
  where p.provider_category = 'toll'
  order by case p.provider_key
    when 'za_sanral_official_tolls' then 1
    when 'za_bakwena_official_tolls' then 2
    when 'za_trac_n4_official_tolls' then 3
    when 'za_n3tc_official_tolls' then 4
    else 10
  end, p.provider_name;
$$;

grant execute on function public.ttaq_toll_provider_status() to authenticated;

create or replace function public.ttaq_calculate_official_route_tolls(
  target_quote_request_id uuid,
  target_route_estimate_id uuid,
  target_equipment_profile_id uuid,
  pricing_date date default current_date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  selected_toll_class integer;
  selected_toll_source text;
  selected_suggested_class integer;
  selected_suggestion_reason text;
  selected_equipment_name text;
  route_payload jsonb := '{}'::jsonb;
  matches jsonb := '[]'::jsonb;
  match_status text := 'unknown';
  match_count integer := 0;
  total_amount numeric := 0;
  plaza_rows jsonb := '[]'::jsonb;
  override_record public.toll_pricing_overrides%rowtype;
  provider_toll_status text;
begin
  select toll_class, toll_class_source, suggested_toll_class, suggested_toll_class_reason, display_name
    into selected_toll_class, selected_toll_source, selected_suggested_class, selected_suggestion_reason, selected_equipment_name
  from public.standard_equipment_profiles
  where id = target_equipment_profile_id;

  select coalesce(provider_response, '{}'::jsonb), coalesce(toll_status, provider_response->>'toll_status')
    into route_payload, provider_toll_status
  from public.route_estimates
  where id = target_route_estimate_id;

  select * into override_record
  from public.toll_pricing_overrides
  where quote_request_id = target_quote_request_id
    and is_active
  order by created_at desc
  limit 1;

  matches := coalesce(route_payload #> '{toll_plaza_matching,matches}', '[]'::jsonb);
  match_status := coalesce(route_payload #>> '{toll_plaza_matching,status}', 'unknown');
  match_count := jsonb_array_length(matches);

  if target_route_estimate_id is null or route_payload = '{}'::jsonb then
    return jsonb_build_object(
      'amount', 0,
      'source', 'manual_review_required',
      'status', 'unknown',
      'requires_review', true,
      'review_warning', 'Toll route geometry is unavailable.',
      'provider_toll_status', provider_toll_status,
      'plazas', '[]'::jsonb
    );
  end if;

  if selected_toll_class is null then
    return jsonb_build_object(
      'amount', 0,
      'source', 'manual_review_required',
      'status', 'equipment_class_unconfigured',
      'requires_review', true,
      'review_warning', 'Toll vehicle class requires confirmation.',
      'equipment', jsonb_build_object(
        'equipment_profile_id', target_equipment_profile_id,
        'display_name', selected_equipment_name,
        'suggested_toll_class', selected_suggested_class,
        'suggested_toll_class_reason', selected_suggestion_reason,
        'toll_class_source', coalesce(selected_toll_source, 'unconfigured')
      ),
      'route_match_status', match_status,
      'provider_toll_status', provider_toll_status,
      'plazas', '[]'::jsonb
    );
  end if;

  if match_status = 'matched' and match_count = 0 and provider_toll_status in ('available', 'expected_unknown') then
    return jsonb_build_object(
      'amount', 0,
      'source', 'manual_review_required',
      'status', 'official_coverage_incomplete',
      'requires_review', true,
      'review_warning', 'Toll pricing requires review - official coverage incomplete.',
      'toll_class', selected_toll_class,
      'route_match_status', match_status,
      'provider_toll_status', provider_toll_status,
      'plazas', '[]'::jsonb
    );
  elsif match_status = 'matched' and match_count = 0 then
    total_amount := 0;
    plaza_rows := '[]'::jsonb;
  elsif match_count > 0 then
    with matched as (
      select distinct (value->>'plaza_id')::uuid as plaza_id,
             coalesce((value->>'distance_m')::numeric, null) as distance_m,
             coalesce(value->>'match_confidence', 'standard') as match_confidence,
             coalesce((value->>'route_order')::integer, (value->>'route_segment_index')::integer, 0) as route_order,
             coalesce(value->>'direction', null) as matched_direction,
             value as match_payload
      from jsonb_array_elements(matches)
      where value ? 'plaza_id'
    ),
    priced as (
      select p.id as plaza_id, p.plaza_name, p.road_route, p.operator_key, p.plaza_type, p.direction,
             t.id as tariff_id, t.effective_from, t.effective_to, t.vat_included, t.source_publication, t.source_url,
             case selected_toll_class
               when 1 then t.class_1_rate
               when 2 then t.class_2_rate
               when 3 then t.class_3_rate
               when 4 then t.class_4_rate
             end as amount,
             m.distance_m, m.match_confidence, m.route_order, m.matched_direction
      from matched m
      join public.toll_plazas p on p.id = m.plaza_id and p.is_active
      join public.pricing_external_providers provider on provider.provider_key = p.operator_key
        and provider.provider_category = 'toll'
        and provider.coverage_status = 'complete'
      join lateral (
        select *
        from public.toll_tariffs tariff
        where tariff.toll_plaza_id = p.id
          and tariff.tariff_status in ('active', 'future')
          and tariff.effective_from <= pricing_date
          and (tariff.effective_to is null or tariff.effective_to >= pricing_date)
        order by tariff.effective_from desc, tariff.created_at desc
        limit 1
      ) t on true
    )
    select coalesce(sum(amount), 0),
           coalesce(jsonb_agg(jsonb_build_object(
             'plaza_id', plaza_id,
             'plaza_name', plaza_name,
             'road_route', road_route,
             'operator_key', operator_key,
             'plaza_type', plaza_type,
             'direction', coalesce(direction, matched_direction),
             'toll_class', selected_toll_class,
             'amount', amount,
             'tariff_id', tariff_id,
             'effective_from', effective_from,
             'effective_to', effective_to,
             'vat_included', vat_included,
             'source_publication', source_publication,
             'source_url', source_url,
             'route_distance_m', distance_m,
             'match_confidence', match_confidence,
             'route_order', route_order,
             'source', 'automatic_official_tariff'
           ) order by route_order, distance_m nulls last, plaza_name), '[]'::jsonb)
      into total_amount, plaza_rows
    from priced;

    if jsonb_array_length(plaza_rows) <> match_count then
      return jsonb_build_object(
        'amount', coalesce(total_amount, 0),
        'source', 'manual_review_required',
        'status', 'official_coverage_incomplete',
        'requires_review', true,
        'review_warning', 'Toll pricing requires review - official coverage incomplete.',
        'toll_class', selected_toll_class,
        'route_match_status', match_status,
        'matched_plaza_count', match_count,
        'priced_plaza_count', jsonb_array_length(plaza_rows),
        'provider_toll_status', provider_toll_status,
        'plazas', plaza_rows
      );
    end if;
  else
    return jsonb_build_object(
      'amount', 0,
      'source', case when provider_toll_status in ('available', 'expected_unknown') then 'live_metadata_no_amount' else 'manual_review_required' end,
      'status', 'unknown',
      'requires_review', true,
      'review_warning', 'Toll amount unknown because route/plaza matching did not complete.',
      'toll_class', selected_toll_class,
      'route_match_status', match_status,
      'provider_toll_status', provider_toll_status,
      'plazas', '[]'::jsonb
    );
  end if;

  if override_record.id is not null then
    return jsonb_build_object(
      'amount', override_record.override_toll_amount,
      'source', 'management_override',
      'status', 'manual_override',
      'requires_review', false,
      'system_amount', total_amount,
      'override_id', override_record.id,
      'override_reason', override_record.override_reason,
      'toll_class', selected_toll_class,
      'toll_class_source', selected_toll_source,
      'route_match_status', match_status,
      'matched_plaza_count', match_count,
      'provider_toll_status', provider_toll_status,
      'plazas', plaza_rows
    );
  end if;

  return jsonb_build_object(
    'amount', coalesce(total_amount, 0),
    'source', case when match_status = 'matched' and match_count = 0 then 'toll_free_route' else 'automatic_official_tariff' end,
    'status', case when match_status = 'matched' and match_count = 0 then 'toll_free' else 'automatic_official' end,
    'requires_review', false,
    'toll_class', selected_toll_class,
    'toll_class_source', selected_toll_source,
    'route_match_status', match_status,
    'matched_plaza_count', match_count,
    'provider_toll_status', provider_toll_status,
    'vat_treatment', 'official tariffs are VAT-inclusive cost inputs; customer quote VAT calculation is preserved separately',
    'plazas', plaza_rows
  );
end;
$$;

revoke all on function public.ttaq_calculate_official_route_tolls(uuid, uuid, uuid, date) from public;
grant execute on function public.ttaq_calculate_official_route_tolls(uuid, uuid, uuid, date) to authenticated;

create or replace function public.ttaq_record_toll_import_result(
  provider_key_value text,
  provider_status_value text,
  publication_effective_date_value date,
  publication_title_value text,
  source_url_value text,
  imported_plaza_count_value integer,
  provider_response_value jsonb default '{}'::jsonb,
  error_message_value text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  run_id uuid;
  normalized_status text := case
    when provider_status_value in ('verified', 'unchanged', 'complete') then 'complete'
    when provider_status_value in ('partial', 'incomplete') then 'partial'
    when provider_status_value in ('unavailable') then 'unavailable'
    else 'needs_review'
  end;
begin
  insert into public.toll_tariff_import_runs (
    provider_key, trigger_source, status, source_url, publication_title, publication_effective_date,
    imported_plaza_count, error_message, provider_response
  )
  values (
    provider_key_value, 'provider_refresh',
    case when normalized_status = 'complete' then 'verified' when normalized_status = 'partial' then 'incomplete' else 'failed' end,
    source_url_value, publication_title_value, publication_effective_date_value,
    coalesce(imported_plaza_count_value, 0), error_message_value, coalesce(provider_response_value, '{}'::jsonb)
  )
  returning id into run_id;

  update public.pricing_external_providers
     set provider_status = normalized_status,
         coverage_status = normalized_status,
         active_plaza_count = coalesce(imported_plaza_count_value, active_plaza_count, 0),
         last_check_at = now(),
         next_expected_check_at = now() + interval '7 days',
         last_success_at = case when normalized_status in ('complete', 'partial') then now() else last_success_at end,
         last_failure_at = case when normalized_status in ('unavailable', 'needs_review') then now() else last_failure_at end,
         last_error = case when normalized_status in ('unavailable', 'needs_review') then error_message_value else null end,
         last_publication_effective_date = coalesce(publication_effective_date_value, last_publication_effective_date),
         last_publication_title = coalesce(publication_title_value, last_publication_title),
         scheduler_status = case when normalized_status in ('complete', 'partial') then 'configured' else 'needs_attention' end,
         endpoint_url = coalesce(source_url_value, endpoint_url),
         updated_at = now()
   where provider_key = provider_key_value;

  return run_id;
end;
$$;

revoke all on function public.ttaq_record_toll_import_result(text, text, date, text, text, integer, jsonb, text) from public;
revoke all on function public.ttaq_record_toll_import_result(text, text, date, text, text, integer, jsonb, text) from anon;
revoke all on function public.ttaq_record_toll_import_result(text, text, date, text, text, integer, jsonb, text) from authenticated;
grant execute on function public.ttaq_record_toll_import_result(text, text, date, text, text, integer, jsonb, text) to service_role;
