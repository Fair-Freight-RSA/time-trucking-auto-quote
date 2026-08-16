create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema extensions;
create extension if not exists supabase_vault with schema vault;

alter table public.standard_equipment_profiles
  add column if not exists toll_class integer,
  add column if not exists toll_class_source text not null default 'unconfigured',
  add column if not exists toll_class_criteria jsonb not null default '{}'::jsonb,
  add column if not exists toll_class_confirmed_by uuid references public.internal_users(id),
  add column if not exists toll_class_confirmed_at timestamptz,
  add column if not exists vehicle_height_m numeric(8, 3),
  add column if not exists axle_count integer,
  add constraint standard_equipment_profiles_toll_class_check check (toll_class is null or toll_class between 1 and 4),
  add constraint standard_equipment_profiles_toll_class_source_check check (toll_class_source in ('automatic_inferred', 'time_trucking_confirmed', 'manual_override', 'unconfigured'));

create table if not exists public.toll_plazas (
  id uuid primary key default gen_random_uuid(),
  plaza_key text not null unique,
  plaza_name text not null,
  road_route text not null,
  operator_key text not null,
  latitude numeric(10, 7) not null,
  longitude numeric(10, 7) not null,
  plaza_type text not null default 'mainline',
  direction text,
  is_active boolean not null default true,
  source_url text,
  source_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint toll_plazas_type_check check (plaza_type in ('mainline', 'ramp', 'other'))
);

create table if not exists public.toll_tariffs (
  id uuid primary key default gen_random_uuid(),
  toll_plaza_id uuid not null references public.toll_plazas(id) on delete cascade,
  class_1_rate numeric(12, 2) not null,
  class_2_rate numeric(12, 2) not null,
  class_3_rate numeric(12, 2) not null,
  class_4_rate numeric(12, 2) not null,
  effective_from date not null,
  effective_to date,
  source_provider text not null,
  source_publication text not null,
  source_url text not null,
  source_metadata jsonb not null default '{}'::jsonb,
  retrieved_at timestamptz not null default now(),
  vat_included boolean not null default true,
  tariff_status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint toll_tariffs_positive_check check (class_1_rate >= 0 and class_2_rate >= 0 and class_3_rate >= 0 and class_4_rate >= 0),
  constraint toll_tariffs_effective_period_check check (effective_to is null or effective_to >= effective_from),
  constraint toll_tariffs_status_check check (tariff_status in ('active', 'future', 'superseded', 'inactive', 'import_failed')),
  unique (toll_plaza_id, effective_from, source_provider)
);

create table if not exists public.toll_tariff_import_runs (
  id uuid primary key default gen_random_uuid(),
  provider_key text not null,
  trigger_source text not null,
  status text not null,
  source_url text,
  publication_title text,
  publication_effective_date date,
  imported_plaza_count integer not null default 0,
  error_message text,
  provider_response jsonb not null default '{}'::jsonb,
  checked_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint toll_tariff_import_status_check check (status in ('verified', 'unchanged', 'failed', 'incomplete'))
);

create table if not exists public.toll_pricing_overrides (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  pricing_calculation_id uuid references public.pricing_calculations(id) on delete set null,
  system_toll_amount numeric(12, 2),
  override_toll_amount numeric(12, 2) not null,
  override_reason text not null,
  override_payload jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  created_by uuid references public.internal_users(id),
  created_at timestamptz not null default now(),
  constraint toll_pricing_overrides_amount_check check (override_toll_amount >= 0),
  constraint toll_pricing_overrides_reason_check check (length(trim(override_reason)) >= 5)
);

create index if not exists ttaq_toll_plazas_active_route_idx on public.toll_plazas(is_active, road_route, operator_key);
create index if not exists ttaq_toll_tariffs_active_idx on public.toll_tariffs(toll_plaza_id, tariff_status, effective_from);
create index if not exists ttaq_toll_overrides_quote_idx on public.toll_pricing_overrides(quote_request_id, is_active, created_at desc);

drop trigger if exists ttaq_toll_plazas_touch_updated_at on public.toll_plazas;
create trigger ttaq_toll_plazas_touch_updated_at
before update on public.toll_plazas
for each row execute function public.ttaq_touch_updated_at();

drop trigger if exists ttaq_toll_tariffs_touch_updated_at on public.toll_tariffs;
create trigger ttaq_toll_tariffs_touch_updated_at
before update on public.toll_tariffs
for each row execute function public.ttaq_touch_updated_at();

alter table public.toll_plazas enable row level security;
alter table public.toll_tariffs enable row level security;
alter table public.toll_tariff_import_runs enable row level security;
alter table public.toll_pricing_overrides enable row level security;

drop policy if exists "Internal users read toll plazas" on public.toll_plazas;
create policy "Internal users read toll plazas" on public.toll_plazas for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

drop policy if exists "Owner manages toll plazas" on public.toll_plazas;
create policy "Owner manages toll plazas" on public.toll_plazas for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read toll tariffs" on public.toll_tariffs;
create policy "Internal users read toll tariffs" on public.toll_tariffs for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

drop policy if exists "Owner manages toll tariffs" on public.toll_tariffs;
create policy "Owner manages toll tariffs" on public.toll_tariffs for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read toll imports" on public.toll_tariff_import_runs;
create policy "Internal users read toll imports" on public.toll_tariff_import_runs for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));

drop policy if exists "Owner manages toll imports" on public.toll_tariff_import_runs;
create policy "Owner manages toll imports" on public.toll_tariff_import_runs for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read toll overrides" on public.toll_pricing_overrides;
create policy "Internal users read toll overrides" on public.toll_pricing_overrides for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

drop policy if exists "Pricing managers write toll overrides" on public.toll_pricing_overrides;
create policy "Pricing managers write toll overrides" on public.toll_pricing_overrides for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

insert into public.pricing_external_providers (
  provider_key, provider_name, provider_category, provider_status, refresh_cadence,
  last_success_at, last_publication_effective_date, last_publication_title, endpoint_url, notes
)
values
  ('za_sanral_official_tolls', 'SANRAL official toll tariffs', 'toll', 'incomplete', 'Weekly source check; Government Gazette/SANRAL tariff import requires complete plaza coordinate catalogue before automatic activation.', null, '2026-03-01', 'SANRAL toll tariff adjustment effective 1 March 2026', 'https://www.nra.co.za/publications/sanral-announces-toll-tariff-adjustment-effective-1-march-2026', 'Provider identified; tariff import not activated until complete official plaza/coordinate dataset is loaded. VAT included.'),
  ('za_bakwena_official_tolls', 'Bakwena N1/N4 official toll tariffs', 'toll', 'configured', 'Weekly source check; records a new tariff set only when publication/effective date changes.', now(), '2026-03-01', 'Bakwena toll tariffs applicable from 1 March 2026 to 28 February 2027', 'https://www.bakwena.co.za/tolls-and-tariffs/', 'Bakwena N1/N4 plazas seeded from operator tariff and GPS-coordinate pages. VAT included.'),
  ('za_trac_n4_official_tolls', 'TRAC N4 official toll tariffs', 'toll', 'incomplete', 'Weekly source check; import blocked until official plaza coordinates are loaded.', null, '2026-03-01', 'TRAC N4 toll fees effective from 1 March 2026', 'https://tracn4.co.za/toll-plazas-toll-fees/', 'Operator tariff source identified; coordinate import required before automatic route charging. VAT included.'),
  ('za_n3tc_official_tolls', 'N3 Toll Concession official toll tariffs', 'toll', 'incomplete', 'Weekly source check; import blocked until official plaza coordinates are loaded.', null, '2026-03-01', 'N3TC toll fee groups effective from 1 March 2026', 'https://www.n3tc.co.za/toll-tariffs/', 'Operator tariff source identified; coordinate import required before automatic route charging. VAT included.')
on conflict (provider_key) do update
set provider_name = excluded.provider_name,
    provider_category = excluded.provider_category,
    provider_status = excluded.provider_status,
    refresh_cadence = excluded.refresh_cadence,
    last_publication_effective_date = excluded.last_publication_effective_date,
    last_publication_title = excluded.last_publication_title,
    endpoint_url = excluded.endpoint_url,
    notes = excluded.notes,
    updated_at = now();

with seeded(plaza_key, plaza_name, road_route, operator_key, latitude, longitude, plaza_type, class_1_rate, class_2_rate, class_3_rate, class_4_rate) as (
  values
    ('bakwena-n1-stormvoel-ramps', 'Stormvoel Ramps', 'N1', 'za_bakwena_official_tolls', -25.7126667, 28.2648333, 'ramp', 12.50, 31.00, 36.00, 44.00),
    ('bakwena-n1-zambesi-ramps', 'Zambesi Ramps', 'N1', 'za_bakwena_official_tolls', -25.6858333, 28.2705000, 'ramp', 15.00, 38.00, 44.00, 53.00),
    ('bakwena-n1-pumulani-mainline', 'Pumulani Mainline', 'N1', 'za_bakwena_official_tolls', -25.6436667, 28.2453333, 'mainline', 16.50, 41.00, 47.00, 57.00),
    ('bakwena-n1-wallmannsthal-ramps', 'Wallmannsthal Ramps', 'N1', 'za_bakwena_official_tolls', -25.5745000, 28.2750000, 'ramp', 7.50, 19.00, 22.50, 26.00),
    ('bakwena-n1-murrayhill-ramps', 'Murrayhill Ramps', 'N1', 'za_bakwena_official_tolls', -25.5036667, 28.2870000, 'ramp', 15.00, 38.00, 45.00, 52.00),
    ('bakwena-n1-hammanskraal-ramps', 'Hammanskraal Ramps', 'N1', 'za_bakwena_official_tolls', -25.4043333, 28.2970000, 'ramp', 35.00, 120.00, 130.00, 150.00),
    ('bakwena-n1-carousel-mainline', 'Carousel Mainline', 'N1', 'za_bakwena_official_tolls', -25.3210000, 28.2920000, 'mainline', 75.00, 202.00, 224.00, 258.00),
    ('bakwena-n1-maubane-ramps', 'Maubane Ramps', 'N1', 'za_bakwena_official_tolls', -25.2816667, 28.2971667, 'ramp', 33.00, 88.00, 97.00, 112.00),
    ('bakwena-n4-doornpoort-mainline', 'Doornpoort Mainline', 'N4', 'za_bakwena_official_tolls', -25.6436667, 28.2453333, 'mainline', 20.00, 50.00, 58.00, 70.00),
    ('bakwena-n4-doornpoort-ramps', 'Doornpoort Ramps', 'N4', 'za_bakwena_official_tolls', -25.6436667, 28.2453333, 'ramp', 20.00, 50.00, 58.00, 70.00),
    ('bakwena-n4-brits-mainline', 'Brits Mainline', 'N4', 'za_bakwena_official_tolls', -25.6500000, 27.9220000, 'mainline', 20.00, 70.00, 77.00, 90.00),
    ('bakwena-n4-buffelspoort-ramps', 'Buffelspoort Ramps', 'N4', 'za_bakwena_official_tolls', -25.7518333, 27.4923333, 'ramp', 20.00, 48.00, 54.00, 64.00),
    ('bakwena-n4-marikana-mainline', 'Marikana Mainline', 'N4', 'za_bakwena_official_tolls', -25.7473333, 27.3976667, 'mainline', 30.00, 72.00, 81.00, 96.00),
    ('bakwena-n4-kroondal-ramps', 'Kroondal Ramps', 'N4', 'za_bakwena_official_tolls', -25.7295000, 27.4923333, 'ramp', 20.00, 48.00, 54.00, 64.00),
    ('bakwena-n4-swartruggens-mainline', 'Swartruggens Mainline', 'N4', 'za_bakwena_official_tolls', -25.6606667, 26.6051667, 'mainline', 103.00, 258.00, 313.00, 368.00)
),
upserted as (
  insert into public.toll_plazas (plaza_key, plaza_name, road_route, operator_key, latitude, longitude, plaza_type, source_url, source_metadata)
  select plaza_key, plaza_name, road_route, operator_key, latitude, longitude, plaza_type,
         'https://www.bakwena.co.za/gps-coordinates/',
         jsonb_build_object('tariff_source_url', 'https://www.bakwena.co.za/tolls-and-tariffs/', 'coordinate_format', 'operator DMM coordinate list converted to decimal degrees')
  from seeded
  on conflict (plaza_key) do update
  set plaza_name = excluded.plaza_name,
      road_route = excluded.road_route,
      operator_key = excluded.operator_key,
      latitude = excluded.latitude,
      longitude = excluded.longitude,
      plaza_type = excluded.plaza_type,
      source_url = excluded.source_url,
      source_metadata = excluded.source_metadata,
      is_active = true,
      updated_at = now()
  returning id, plaza_key
)
insert into public.toll_tariffs (
  toll_plaza_id, class_1_rate, class_2_rate, class_3_rate, class_4_rate,
  effective_from, effective_to, source_provider, source_publication, source_url, source_metadata, vat_included, tariff_status
)
select p.id, s.class_1_rate, s.class_2_rate, s.class_3_rate, s.class_4_rate,
       date '2026-03-01', date '2027-02-28', 'za_bakwena_official_tolls',
       'Bakwena toll tariffs applicable from 1 March 2026 to 28 February 2027',
       'https://www.bakwena.co.za/tolls-and-tariffs/',
       jsonb_build_object('operator', 'Bakwena', 'currency', 'ZAR', 'vat_included', true),
       true,
       case when current_date < date '2026-03-01' then 'future' else 'active' end
from seeded s
join public.toll_plazas p on p.plaza_key = s.plaza_key
on conflict (toll_plaza_id, effective_from, source_provider) do update
set class_1_rate = excluded.class_1_rate,
    class_2_rate = excluded.class_2_rate,
    class_3_rate = excluded.class_3_rate,
    class_4_rate = excluded.class_4_rate,
    effective_to = excluded.effective_to,
    source_publication = excluded.source_publication,
    source_url = excluded.source_url,
    source_metadata = excluded.source_metadata,
    vat_included = excluded.vat_included,
    tariff_status = excluded.tariff_status,
    updated_at = now();

create or replace function public.ttaq_current_toll_catalogue()
returns table (
  plaza_id uuid,
  plaza_name text,
  road_route text,
  operator_key text,
  plaza_type text,
  latitude numeric,
  longitude numeric,
  class_1_rate numeric,
  class_2_rate numeric,
  class_3_rate numeric,
  class_4_rate numeric,
  effective_from date,
  effective_to date,
  vat_included boolean,
  source_publication text,
  source_url text
)
language sql
security definer
set search_path = public
as $$
  select p.id, p.plaza_name, p.road_route, p.operator_key, p.plaza_type, p.latitude, p.longitude,
         t.class_1_rate, t.class_2_rate, t.class_3_rate, t.class_4_rate,
         t.effective_from, t.effective_to, t.vat_included, t.source_publication, t.source_url
  from public.toll_plazas p
  join lateral (
    select *
    from public.toll_tariffs tariff
    where tariff.toll_plaza_id = p.id
      and tariff.tariff_status in ('active', 'future')
      and tariff.effective_from <= current_date
      and (tariff.effective_to is null or tariff.effective_to >= current_date)
    order by tariff.effective_from desc, tariff.created_at desc
    limit 1
  ) t on true
  where p.is_active
  order by p.operator_key, p.road_route, p.plaza_name;
$$;

grant execute on function public.ttaq_current_toll_catalogue() to authenticated;

create or replace function public.ttaq_toll_provider_status()
returns table (
  provider_key text,
  provider_name text,
  provider_status text,
  last_check_at timestamptz,
  last_success_at timestamptz,
  last_failure_at timestamptz,
  last_error text,
  next_expected_check_at timestamptz,
  last_publication_effective_date date,
  last_publication_title text,
  scheduler_status text,
  source_url text
)
language sql
security definer
set search_path = public
as $$
  select provider_key, provider_name, provider_status, last_check_at, last_success_at, last_failure_at, last_error,
         next_expected_check_at, last_publication_effective_date, last_publication_title, scheduler_status, endpoint_url as source_url
  from public.pricing_external_providers
  where provider_category = 'toll'
  order by provider_status = 'configured' desc, provider_name;
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
  select toll_class, toll_class_source, display_name
    into selected_toll_class, selected_toll_source, selected_equipment_name
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
      'equipment', jsonb_build_object('equipment_profile_id', target_equipment_profile_id, 'display_name', selected_equipment_name, 'toll_class_source', coalesce(selected_toll_source, 'unconfigured')),
      'route_match_status', match_status,
      'provider_toll_status', provider_toll_status,
      'plazas', '[]'::jsonb
    );
  end if;

  if match_status = 'matched' and match_count = 0 then
    total_amount := 0;
    plaza_rows := '[]'::jsonb;
  elsif match_count > 0 then
    with matched as (
      select distinct (value->>'plaza_id')::uuid as plaza_id,
             coalesce((value->>'distance_m')::numeric, null) as distance_m,
             value as match_payload
      from jsonb_array_elements(matches)
      where value ? 'plaza_id'
    ),
    priced as (
      select p.id as plaza_id, p.plaza_name, p.road_route, p.operator_key, p.plaza_type,
             t.id as tariff_id, t.effective_from, t.effective_to, t.vat_included, t.source_publication, t.source_url,
             case selected_toll_class
               when 1 then t.class_1_rate
               when 2 then t.class_2_rate
               when 3 then t.class_3_rate
               when 4 then t.class_4_rate
             end as amount,
             m.distance_m
      from matched m
      join public.toll_plazas p on p.id = m.plaza_id and p.is_active
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
             'toll_class', selected_toll_class,
             'amount', amount,
             'tariff_id', tariff_id,
             'effective_from', effective_from,
             'effective_to', effective_to,
             'vat_included', vat_included,
             'source_publication', source_publication,
             'source_url', source_url,
             'route_distance_m', distance_m,
             'source', 'automatic_official_tariff'
           ) order by distance_m nulls last, plaza_name), '[]'::jsonb)
      into total_amount, plaza_rows
    from priced;

    if jsonb_array_length(plaza_rows) <> match_count then
      return jsonb_build_object(
        'amount', coalesce(total_amount, 0),
        'source', 'manual_review_required',
        'status', 'missing_applicable_tariff',
        'requires_review', true,
        'review_warning', 'A matched toll plaza has no current official tariff.',
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

create or replace function public.ttaq_apply_official_toll_pricing_enrichment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  route_record public.route_estimates%rowtype;
  recommendation_record public.vehicle_recommendations%rowtype;
  request_record public.quote_requests%rowtype;
  toll_result jsonb := '{}'::jsonb;
  source_value text;
  old_toll_amount numeric := 0;
  new_toll_amount numeric := 0;
  delta_amount numeric := 0;
  adjusted_subtotal numeric;
  adjusted_profit numeric;
  vat_rate numeric := 0;
  adjusted_vat numeric;
  adjusted_total numeric;
  margin_rate numeric := 0;
  min_profit numeric := 0;
begin
  if new.rule_version not like 'pricing-v3%' then
    return new;
  end if;

  select * into request_record
  from public.quote_requests
  where id = new.quote_request_id;

  select * into route_record
  from public.route_estimates
  where quote_request_id = new.quote_request_id
  order by created_at desc
  limit 1;

  select * into recommendation_record
  from public.vehicle_recommendations
  where id = new.vehicle_recommendation_id;

  toll_result := public.ttaq_calculate_official_route_tolls(
    new.quote_request_id,
    route_record.id,
    recommendation_record.final_equipment_profile_id,
    coalesce(request_record.collection_date, current_date)
  );

  source_value := toll_result->>'source';

  if source_value in ('automatic_official_tariff', 'toll_free_route', 'management_override') then
    old_toll_amount := coalesce(new.toll_amount, 0);
    new_toll_amount := coalesce((toll_result->>'amount')::numeric, 0);
    delta_amount := new_toll_amount - old_toll_amount;
    adjusted_subtotal := round(coalesce(new.subtotal, 0) + delta_amount, 2);
    margin_rate := coalesce(new.margin_percent, 0) / 100;
    min_profit := coalesce((new.pricing_source_snapshot #>> '{commercial,minimum_profit}')::numeric, 0);
    adjusted_profit := greatest(round(adjusted_subtotal * margin_rate, 2), min_profit, 0);
    vat_rate := case when coalesce(new.subtotal, 0) + coalesce(new.profit_amount, 0) > 0
      then coalesce(new.vat_amount, 0) / (coalesce(new.subtotal, 0) + coalesce(new.profit_amount, 0))
      else 0
    end;
    adjusted_vat := round((adjusted_subtotal + adjusted_profit) * vat_rate, 2);
    adjusted_total := adjusted_subtotal + adjusted_profit + adjusted_vat;

    update public.pricing_calculations
       set toll_amount = new_toll_amount,
           subtotal = adjusted_subtotal,
           profit_amount = adjusted_profit,
           vat_amount = adjusted_vat,
           grand_total = adjusted_total,
           recommended_selling_price = adjusted_total,
           dynamic_outputs = coalesce(dynamic_outputs, '{}'::jsonb)
             || jsonb_build_object(
               'toll_amount', new_toll_amount,
               'calculated_cost_before_profit_vat', adjusted_subtotal,
               'profit_amount', adjusted_profit,
               'vat_amount', adjusted_vat,
               'grand_total', adjusted_total,
               'toll_pricing_delta', delta_amount
             ),
           pricing_source_snapshot = coalesce(pricing_source_snapshot, '{}'::jsonb)
             || jsonb_build_object('tolls', toll_result),
           dynamic_inputs = coalesce(dynamic_inputs, '{}'::jsonb)
             || jsonb_build_object('tolls', toll_result),
           automation_status = coalesce(automation_status, '{}'::jsonb)
             || jsonb_build_object(
               'toll_requires_review', coalesce((toll_result->>'requires_review')::boolean, false),
               'toll_status', toll_result->>'status',
               'toll_review_warning', toll_result->>'review_warning'
             ),
           manager_review_required = coalesce(manager_review_required, false) or coalesce((toll_result->>'requires_review')::boolean, false)
     where id = new.id;

    update public.pricing_breakdowns
       set quantity = greatest(coalesce((toll_result->>'matched_plaza_count')::numeric, 0), 1),
           unit_rate = new_toll_amount,
           amount = new_toll_amount,
           explanation = case
             when source_value = 'toll_free_route' then 'Official plaza matching completed and no toll plazas apply to this route.'
             when source_value = 'management_override' then 'Management override applied after official toll calculation snapshot.'
             else 'Official VAT-inclusive toll tariff matched to route geometry and confirmed equipment toll class.'
           end
     where pricing_calculation_id = new.id
       and line_key = 'tolls';
  elsif coalesce((toll_result->>'requires_review')::boolean, false) then
    update public.pricing_calculations
       set pricing_source_snapshot = coalesce(pricing_source_snapshot, '{}'::jsonb)
             || jsonb_build_object('tolls', coalesce(pricing_source_snapshot->'tolls', '{}'::jsonb) || toll_result),
           automation_status = coalesce(automation_status, '{}'::jsonb)
             || jsonb_build_object(
               'toll_requires_review', true,
               'toll_status', toll_result->>'status',
               'toll_review_warning', toll_result->>'review_warning'
             ),
           manager_review_required = true
     where id = new.id;
  end if;

  return new;
end;
$$;

drop trigger if exists ttaq_apply_official_toll_pricing_enrichment on public.pricing_calculations;
create trigger ttaq_apply_official_toll_pricing_enrichment
after insert on public.pricing_calculations
for each row execute function public.ttaq_apply_official_toll_pricing_enrichment();

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
    when provider_status_value in ('verified', 'unchanged') then provider_status_value
    when provider_status_value in ('failed', 'incomplete') then provider_status_value
    else 'failed'
  end;
begin
  insert into public.toll_tariff_import_runs (
    provider_key, trigger_source, status, source_url, publication_title, publication_effective_date,
    imported_plaza_count, error_message, provider_response
  )
  values (
    provider_key_value, 'provider_refresh', normalized_status, source_url_value, publication_title_value,
    publication_effective_date_value, coalesce(imported_plaza_count_value, 0), error_message_value, coalesce(provider_response_value, '{}'::jsonb)
  )
  returning id into run_id;

  update public.pricing_external_providers
     set provider_status = case when normalized_status in ('verified', 'unchanged') then 'configured' else normalized_status end,
         last_check_at = now(),
         next_expected_check_at = now() + interval '7 days',
         last_success_at = case when normalized_status in ('verified', 'unchanged') then now() else last_success_at end,
         last_failure_at = case when normalized_status in ('failed', 'incomplete') then now() else last_failure_at end,
         last_error = case when normalized_status in ('failed', 'incomplete') then error_message_value else null end,
         last_publication_effective_date = coalesce(publication_effective_date_value, last_publication_effective_date),
         last_publication_title = coalesce(publication_title_value, last_publication_title),
         scheduler_status = case when normalized_status in ('verified', 'unchanged') then 'configured' else 'needs_attention' end,
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

create or replace function public.ttaq_trigger_official_toll_refresh(trigger_source_value text default 'scheduled')
returns bigint
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  refresh_secret text;
  publishable_key text;
  request_id bigint;
begin
  select decrypted_secret into refresh_secret
  from vault.decrypted_secrets
  where name = 'ttaq_diesel_refresh_secret'
  order by created_at desc
  limit 1;

  select decrypted_secret into publishable_key
  from vault.decrypted_secrets
  where name = 'ttaq_supabase_publishable_key'
  order by created_at desc
  limit 1;

  if nullif(refresh_secret, '') is null or nullif(publishable_key, '') is null then
    update public.pricing_external_providers
       set provider_status = 'failed',
           scheduler_status = 'needs_attention',
           last_failure_at = now(),
           last_error = 'Toll refresh scheduler is missing Vault secrets.'
     where provider_category = 'toll';
    raise exception 'Toll refresh scheduler is missing Vault secrets.';
  end if;

  select net.http_post(
    url := 'https://uxbbmrmkiopacaxdwvrp.functions.supabase.co/production-integrations',
    body := jsonb_build_object('action', 'refresh_official_tolls'),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', publishable_key,
      'Authorization', 'Bearer ' || publishable_key,
      'x-diesel-refresh-secret', refresh_secret
    ),
    timeout_milliseconds := 15000
  ) into request_id;

  update public.pricing_external_providers
     set last_check_at = now(),
         next_expected_check_at = now() + interval '7 days',
         scheduler_status = 'queued',
         last_error = null
   where provider_category = 'toll';

  insert into public.pricing_provider_refresh_runs (provider_key, trigger_source, request_id, status)
  values ('za_official_toll_tariffs', coalesce(nullif(trigger_source_value, ''), 'scheduled'), request_id, 'queued');

  return request_id;
end;
$$;

revoke all on function public.ttaq_trigger_official_toll_refresh(text) from public;
revoke all on function public.ttaq_trigger_official_toll_refresh(text) from anon;
revoke all on function public.ttaq_trigger_official_toll_refresh(text) from authenticated;
grant execute on function public.ttaq_trigger_official_toll_refresh(text) to service_role;

create or replace function public.ttaq_install_toll_refresh_schedule()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform cron.unschedule('ttaq-weekly-official-toll-refresh')
  where exists (select 1 from cron.job where jobname = 'ttaq-weekly-official-toll-refresh');

  perform cron.schedule(
    'ttaq-weekly-official-toll-refresh',
    '23 5 * * 1',
    $job$select public.ttaq_trigger_official_toll_refresh('scheduled');$job$
  );

  update public.pricing_external_providers
     set scheduler_status = 'configured',
         next_expected_check_at = coalesce(next_expected_check_at, now() + interval '7 days')
   where provider_category = 'toll';
end;
$$;

revoke all on function public.ttaq_install_toll_refresh_schedule() from public;
revoke all on function public.ttaq_install_toll_refresh_schedule() from anon;
revoke all on function public.ttaq_install_toll_refresh_schedule() from authenticated;
grant execute on function public.ttaq_install_toll_refresh_schedule() to service_role;
