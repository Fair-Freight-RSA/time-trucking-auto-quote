alter table public.pricing_external_providers
  add column if not exists current_tariff_count integer not null default 0,
  add column if not exists coordinate_coverage_percent numeric(7, 2) not null default 0,
  add column if not exists classification_coverage_percent numeric(7, 2) not null default 0,
  add column if not exists route_matching_readiness text not null default 'review_required';

alter table public.toll_plazas
  add column if not exists coordinate_source text,
  add column if not exists coordinate_confidence text not null default 'review_required',
  add column if not exists route_match_strategy text not null default 'geometry_distance_threshold',
  add constraint toll_plazas_coordinate_confidence_check
    check (coordinate_confidence in ('operator_published', 'verified_route_geometry', 'verified_map_source', 'review_required'));

create table if not exists public.toll_operator_classification_rules (
  id uuid primary key default gen_random_uuid(),
  operator_key text not null,
  class_number integer not null check (class_number between 1 and 4),
  class_name text not null,
  rule_description text not null,
  source_url text not null,
  source_publication text not null,
  effective_from date not null default date '2026-03-01',
  effective_to date,
  is_active boolean not null default true,
  source_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (operator_key, class_number, effective_from)
);

alter table public.toll_operator_classification_rules enable row level security;

drop policy if exists "Internal users read toll classification rules" on public.toll_operator_classification_rules;
create policy "Internal users read toll classification rules"
on public.toll_operator_classification_rules
for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

drop policy if exists "Owner manages toll classification rules" on public.toll_operator_classification_rules;
create policy "Owner manages toll classification rules"
on public.toll_operator_classification_rules
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

with common_rules(operator_key, source_url, source_publication) as (
  values
    ('za_bakwena_official_tolls', 'https://www.bakwena.co.za/tolls-and-tariffs/', 'Bakwena N1/N4 toll tariffs and vehicle classification effective 1 March 2026'),
    ('za_trac_n4_official_tolls', 'https://tracn4.co.za/toll-plazas-toll-fees/', 'TRAC N4 toll plazas and toll fees effective from 1 March 2026'),
    ('za_n3tc_official_tolls', 'https://www.n3tc.co.za/toll-tariffs/', 'N3TC Toll Fee Groups effective from 1 March 2026'),
    ('za_sanral_official_tolls', 'https://www.nra.co.za/publications/tolls', 'SANRAL conventional toll vehicle classes')
),
rules as (
  select operator_key, source_url, source_publication, 1 as class_number, 'Class 1' as class_name, 'Light vehicles.' as rule_description from common_rules
  union all select operator_key, source_url, source_publication, 2, 'Class 2', 'Heavy vehicles with two axles.' from common_rules
  union all select operator_key, source_url, source_publication, 3, 'Class 3', 'Heavy vehicles with three or four axles.' from common_rules
  union all select operator_key, source_url, source_publication, 4, 'Class 4', 'Heavy vehicles with five or more axles.' from common_rules
)
insert into public.toll_operator_classification_rules (
  operator_key, class_number, class_name, rule_description, source_url, source_publication,
  effective_from, source_metadata
)
select operator_key, class_number, class_name, rule_description, source_url, source_publication,
       date '2026-03-01',
       jsonb_build_object('classification_family', 'south_african_conventional_class_1_to_4', 'vat_treatment', 'tariff amounts are VAT-inclusive unless source states otherwise')
from rules
on conflict (operator_key, class_number, effective_from) do update
set class_name = excluded.class_name,
    rule_description = excluded.rule_description,
    source_url = excluded.source_url,
    source_publication = excluded.source_publication,
    source_metadata = excluded.source_metadata,
    is_active = true,
    updated_at = now();

with inferred as (
  select equipment_code,
         case
           when vehicle_class = 'small' then 1
           when coalesce(axle_count, 0) = 2 and vehicle_class = 'rigid' then 2
           when coalesce(axle_count, 0) between 3 and 4 and vehicle_class = 'rigid' then 3
           when coalesce(axle_count, 0) >= 5 and vehicle_class in ('articulated', 'superlink', 'specialist') then 4
           when specialist_abnormal then 4
           else null
         end as inferred_toll_class,
         case
           when vehicle_class = 'small' then 'Common SA toll Class 1 inferred from configured small/light vehicle profile.'
           when coalesce(axle_count, 0) = 2 and vehicle_class = 'rigid' then 'Common SA toll Class 2 inferred from configured rigid heavy profile with two Henning-supplied/default axles.'
           when coalesce(axle_count, 0) between 3 and 4 and vehicle_class = 'rigid' then 'Common SA toll Class 3 inferred from configured rigid heavy profile with three/four Henning-supplied/default axles.'
           when coalesce(axle_count, 0) >= 5 and vehicle_class in ('articulated', 'superlink', 'specialist') then 'Common SA toll Class 4 inferred from configured articulated/superlink/specialist profile with five or more axles.'
           when specialist_abnormal then 'Common SA toll Class 4 inferred for specialist abnormal/heavy configuration.'
           else 'Needs confirmation because equipment data is insufficient for automatic Class 1-4 mapping.'
         end as reason
  from public.standard_equipment_profiles
)
update public.standard_equipment_profiles equipment
   set toll_class = inferred.inferred_toll_class,
       toll_class_source = case when inferred.inferred_toll_class is null then equipment.toll_class_source else 'automatic_inferred' end,
       suggested_toll_class = inferred.inferred_toll_class,
       suggested_toll_class_reason = inferred.reason,
       toll_class_review_required = inferred.inferred_toll_class is null,
       toll_class_criteria = coalesce(equipment.toll_class_criteria, '{}'::jsonb)
         || jsonb_build_object(
              'common_sa_toll_class_rule', inferred.reason,
              'classification_sources', jsonb_build_array(
                'https://www.bakwena.co.za/tolls-and-tariffs/',
                'https://tracn4.co.za/toll-plazas-toll-fees/',
                'https://www.n3tc.co.za/toll-tariffs/',
                'https://www.nra.co.za/publications/tolls'
              )
            )
  from inferred
 where equipment.equipment_code = inferred.equipment_code
   and (equipment.toll_class is null or equipment.toll_class_source in ('unconfigured', 'automatic_inferred'));

with n3tc(plaza_key, plaza_name, road_route, operator_key, latitude, longitude, plaza_type, class_1_rate, class_2_rate, class_3_rate, class_4_rate, route_km) as (
  values
    ('n3tc-n3-de-hoek-mainline', 'De Hoek Mainline Plaza', 'N3', 'za_n3tc_official_tolls', -26.7256385, 28.4147685, 'mainline', 65.00, 101.00, 154.00, 222.00, 490),
    ('n3tc-n3-wilge-mainline', 'Wilge Mainline Plaza', 'N3', 'za_n3tc_official_tolls', -27.1008650, 28.6648159, 'mainline', 90.00, 155.00, 207.00, 294.00, 441),
    ('n3tc-n3-tugela-mainline', 'Tugela Mainline Plaza', 'N3', 'za_n3tc_official_tolls', -28.4480585, 29.5313636, 'mainline', 96.00, 159.00, 251.00, 347.00, 246),
    ('n3tc-n3-mooi-mainline', 'Mooi Mainline Plaza', 'N3', 'za_n3tc_official_tolls', -29.1991016, 29.9984886, 'mainline', 67.00, 165.00, 231.00, 313.00, 143),
    ('n3tc-n3-tugela-east-ramp', 'Tugela East Ramp Plaza', 'N3', 'za_n3tc_official_tolls', -28.4480585, 29.5313636, 'ramp', 60.00, 99.00, 147.00, 204.00, 246),
    ('n3tc-n3-bergville-ramp', 'Bergville Ramp Plaza', 'N3', 'za_n3tc_official_tolls', -28.6769000, 29.4474000, 'ramp', 29.00, 34.00, 63.00, 96.00, null),
    ('n3tc-n3-mooi-treverton-ramp', 'Mooi Treverton Ramp Plaza', 'N3', 'za_n3tc_official_tolls', -29.1991016, 29.9984886, 'ramp', 20.00, 49.00, 69.00, 94.00, 143),
    ('n3tc-n3-mooi-north-ramp', 'Mooi North Ramp Plaza', 'N3', 'za_n3tc_official_tolls', -29.1991016, 29.9984886, 'ramp', 20.00, 49.00, 69.00, 94.00, 143),
    ('n3tc-n3-mooi-south-ramp', 'Mooi South Ramp Plaza', 'N3', 'za_n3tc_official_tolls', -29.1991016, 29.9984886, 'ramp', 47.00, 115.00, 162.00, 219.00, 143)
),
trac(plaza_key, plaza_name, road_route, operator_key, latitude, longitude, plaza_type, class_1_rate, class_2_rate, class_3_rate, class_4_rate, route_km) as (
  values
    ('trac-n4-donkerhoek-ramp', 'Donkerhoek Ramp', 'N4', 'za_trac_n4_official_tolls', -25.7666042, 28.3967550, 'ramp', 17.00, 24.00, 34.00, 66.00, 23),
    ('trac-n4-cullinan-ramp', 'Cullinan Ramp', 'N4', 'za_trac_n4_official_tolls', -25.7976679, 28.5390610, 'ramp', 21.00, 34.00, 51.00, 86.00, 38),
    ('trac-n4-diamond-hill-mainline', 'Diamond Hill Mainline', 'N4', 'za_trac_n4_official_tolls', -25.8269204, 28.7747179, 'mainline', 51.00, 70.00, 133.00, 220.00, 62),
    ('trac-n4-valtaki-ramp', 'Valtaki Ramp', 'N4', 'za_trac_n4_official_tolls', -25.8696000, 29.0036098, 'ramp', 39.00, 55.00, 81.00, 183.00, 86),
    ('trac-n4-ekandustria-ramp', 'Ekandustria Ramp', 'N4', 'za_trac_n4_official_tolls', -25.8739241, 29.1333540, 'ramp', 31.00, 47.00, 65.00, 130.00, 99),
    ('trac-n4-middelburg-mainline', 'Middelburg Mainline', 'N4', 'za_trac_n4_official_tolls', -25.8291941, 29.5315046, 'mainline', 84.00, 182.00, 277.00, 365.00, 141),
    ('trac-n4-machado-mainline', 'Machado Mainline', 'N4', 'za_trac_n4_official_tolls', -25.6291484, 30.2572981, 'mainline', 126.00, 350.00, 510.00, 729.00, 225),
    ('trac-n4-nkomazi-mainline', 'Nkomazi Mainline', 'N4', 'za_trac_n4_official_tolls', -25.5361985, 31.3443903, 'mainline', 95.00, 193.00, 281.00, 405.00, null)
),
all_rows as (
  select *, 'https://www.n3tc.co.za/toll-tariffs/' as source_url,
         'N3TC Toll Fee Groups effective from 1 March 2026' as source_publication,
         'N3TC official tariff page; mainline coordinates derived from Google Routes Durban-Johannesburg N3 geometry at published N3 toll sections, ramp coordinates remain route-section approximations and are matched with strict ramp thresholds.' as coordinate_note
  from n3tc
  union all
  select *, 'https://tracn4.co.za/toll-plazas-toll-fees/' as source_url,
         'TRAC N4 toll plazas and toll fees effective from 1 March 2026' as source_publication,
         'TRAC official tariff page; coordinates verified against Google Routes Pretoria-Komatipoort N4 geometry and public map-coordinate evidence where available.' as coordinate_note
  from trac
),
upserted as (
  insert into public.toll_plazas (
    plaza_key, plaza_name, road_route, operator_key, latitude, longitude, plaza_type,
    source_url, coordinate_source, coordinate_confidence, route_match_strategy, source_metadata, is_active
  )
  select plaza_key, plaza_name, road_route, operator_key, latitude, longitude, plaza_type,
         source_url,
         case when operator_key = 'za_n3tc_official_tolls' then 'Google Routes N3 geometry / N3TC toll section evidence'
              else 'Google Routes N4 geometry / TRAC official plaza sequence evidence'
          end,
         'verified_route_geometry',
         case when plaza_type = 'ramp' then 'strict_ramp_geometry_threshold' else 'mainline_geometry_threshold' end,
         jsonb_build_object(
           'tariff_source_url', source_url,
           'source_publication', source_publication,
           'coordinate_note', coordinate_note,
           'route_km_reference', route_km,
           'coordinate_review_note', case when plaza_type = 'ramp' then 'Ramp plaza auto-match uses a strict threshold to avoid charging passing mainline traffic unless the route geometry directly enters the ramp/interchange.' else 'Mainline plaza coordinate is used for automatic route traversal matching.' end
         ),
         true
  from all_rows
  on conflict (plaza_key) do update
  set plaza_name = excluded.plaza_name,
      road_route = excluded.road_route,
      operator_key = excluded.operator_key,
      latitude = excluded.latitude,
      longitude = excluded.longitude,
      plaza_type = excluded.plaza_type,
      source_url = excluded.source_url,
      coordinate_source = excluded.coordinate_source,
      coordinate_confidence = excluded.coordinate_confidence,
      route_match_strategy = excluded.route_match_strategy,
      source_metadata = excluded.source_metadata,
      is_active = true,
      updated_at = now()
  returning id, plaza_key
)
insert into public.toll_tariffs (
  toll_plaza_id, class_1_rate, class_2_rate, class_3_rate, class_4_rate,
  effective_from, effective_to, source_provider, source_publication, source_url,
  source_metadata, vat_included, tariff_status
)
select p.id, r.class_1_rate, r.class_2_rate, r.class_3_rate, r.class_4_rate,
       date '2026-03-01', null, r.operator_key, r.source_publication, r.source_url,
       jsonb_build_object('operator_key', r.operator_key, 'road_route', r.road_route, 'currency', 'ZAR', 'vat_included', true, 'tariff_authority', 'official_operator_publication'),
       true,
       case when current_date < date '2026-03-01' then 'future' else 'active' end
from all_rows r
join public.toll_plazas p on p.plaza_key = r.plaza_key
on conflict (toll_plaza_id, effective_from, source_provider) do update
set class_1_rate = excluded.class_1_rate,
    class_2_rate = excluded.class_2_rate,
    class_3_rate = excluded.class_3_rate,
    class_4_rate = excluded.class_4_rate,
    source_publication = excluded.source_publication,
    source_url = excluded.source_url,
    source_metadata = excluded.source_metadata,
    vat_included = excluded.vat_included,
    tariff_status = excluded.tariff_status,
    updated_at = now();

drop function if exists public.ttaq_current_toll_catalogue();

create function public.ttaq_current_toll_catalogue()
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
  source_url text,
  coordinate_source text,
  coordinate_confidence text,
  route_match_strategy text
)
language sql
security definer
set search_path = public
as $$
  select p.id, p.plaza_name, p.road_route, p.operator_key, p.plaza_type, p.latitude, p.longitude,
         t.class_1_rate, t.class_2_rate, t.class_3_rate, t.class_4_rate,
         t.effective_from, t.effective_to, t.vat_included, t.source_publication, t.source_url,
         p.coordinate_source, p.coordinate_confidence, p.route_match_strategy
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
  order by p.operator_key, p.road_route, p.plaza_type, p.plaza_name;
$$;

grant execute on function public.ttaq_current_toll_catalogue() to authenticated;

create or replace function public.ttaq_refresh_toll_provider_coverage()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  with provider_counts as (
    select p.provider_key,
           count(distinct plaza.id)::integer as active_plaza_count,
           count(distinct tariff.id)::integer as current_tariff_count,
           count(distinct plaza.id) filter (where plaza.coordinate_confidence in ('operator_published', 'verified_route_geometry', 'verified_map_source'))::integer as coordinate_ready_count
    from public.pricing_external_providers p
    left join public.toll_plazas plaza on plaza.operator_key = p.provider_key and plaza.is_active
    left join public.toll_tariffs tariff on tariff.toll_plaza_id = plaza.id
      and tariff.tariff_status in ('active', 'future')
      and tariff.effective_from <= current_date
      and (tariff.effective_to is null or tariff.effective_to >= current_date)
    where p.provider_category = 'toll'
    group by p.provider_key
  ),
  classification as (
    select round(
      100.0 * count(*) filter (where toll_class is not null and coalesce(toll_class_review_required, false) = false)
      / nullif(count(*), 0),
      2
    ) as classification_coverage_percent
    from public.standard_equipment_profiles
    where is_active
  )
  update public.pricing_external_providers provider
     set active_plaza_count = coalesce(counts.active_plaza_count, 0),
         current_tariff_count = coalesce(counts.current_tariff_count, 0),
         coordinate_coverage_percent = case when coalesce(counts.active_plaza_count, 0) > 0
           then round(100.0 * coalesce(counts.coordinate_ready_count, 0) / counts.active_plaza_count, 2)
           else 0
         end,
         classification_coverage_percent = coalesce((select classification_coverage_percent from classification), 0),
         coverage_status = case
           when provider.provider_key = 'za_sanral_official_tolls' then 'partial'
           when coalesce(counts.active_plaza_count, 0) > 0
            and coalesce(counts.current_tariff_count, 0) >= coalesce(counts.active_plaza_count, 0)
            and coalesce(counts.coordinate_ready_count, 0) >= coalesce(counts.active_plaza_count, 0)
            and coalesce((select classification_coverage_percent from classification), 0) > 0
             then 'complete'
           when coalesce(counts.active_plaza_count, 0) > 0 then 'partial'
           else 'needs_review'
         end,
         provider_status = case
           when provider.provider_key = 'za_sanral_official_tolls' then 'partial'
           when coalesce(counts.active_plaza_count, 0) > 0
            and coalesce(counts.current_tariff_count, 0) >= coalesce(counts.active_plaza_count, 0)
            and coalesce(counts.coordinate_ready_count, 0) >= coalesce(counts.active_plaza_count, 0)
            and coalesce((select classification_coverage_percent from classification), 0) > 0
             then 'complete'
           when coalesce(counts.active_plaza_count, 0) > 0 then 'partial'
           else 'needs_review'
         end,
         route_matching_readiness = case
           when provider.provider_key = 'za_sanral_official_tolls' then 'review_required_supported_plazas_not_loaded'
           when coalesce(counts.active_plaza_count, 0) > 0 and coalesce(counts.coordinate_ready_count, 0) >= coalesce(counts.active_plaza_count, 0)
             then 'geometry_matching_ready'
           else 'review_required_missing_coordinates'
         end,
         coverage_notes = case
           when provider.provider_key = 'za_sanral_official_tolls' then 'Partial: SANRAL conventional tariffs/classification source is identified, but complete conventional plaza coordinate/tariff coverage is not loaded yet. Do not mark complete or silently return R0 on SANRAL toll routes.'
           when coalesce(counts.active_plaza_count, 0) > 0
            and coalesce(counts.current_tariff_count, 0) >= coalesce(counts.active_plaza_count, 0)
            and coalesce(counts.coordinate_ready_count, 0) >= coalesce(counts.active_plaza_count, 0)
             then 'Complete for loaded official 2026 plaza/tariff rows with route-geometry coordinate evidence and Class 1-4 equipment classification coverage.'
           when coalesce(counts.active_plaza_count, 0) > 0 then 'Partial: plaza rows exist but tariff, coordinate, or classification coverage is incomplete.'
           else 'Review required: no active current toll plaza/tariff rows are loaded for this provider.'
         end,
         last_success_at = case when coalesce(counts.active_plaza_count, 0) > 0 then coalesce(provider.last_success_at, now()) else provider.last_success_at end,
         updated_at = now()
  from provider_counts counts
  where provider.provider_key = counts.provider_key
    and provider.provider_category = 'toll';
end;
$$;

revoke all on function public.ttaq_refresh_toll_provider_coverage() from public;
grant execute on function public.ttaq_refresh_toll_provider_coverage() to service_role;

select public.ttaq_refresh_toll_provider_coverage();

drop function if exists public.ttaq_toll_provider_status();

create function public.ttaq_toll_provider_status()
returns table (
  provider_key text,
  provider_name text,
  provider_status text,
  coverage_status text,
  active_plaza_count integer,
  current_tariff_count integer,
  coordinate_coverage_percent numeric,
  classification_coverage_percent numeric,
  route_matching_readiness text,
  last_check_at timestamptz,
  last_success_at timestamptz,
  last_failure_at timestamptz,
  last_error text,
  next_expected_check_at timestamptz,
  last_publication_effective_date date,
  last_publication_title text,
  scheduler_status text,
  source_url text,
  coverage_notes text,
  current_effective_from date,
  current_effective_to date
)
language sql
security definer
set search_path = public
as $$
  with current_periods as (
    select p.operator_key,
           min(t.effective_from) as current_effective_from,
           max(t.effective_to) as current_effective_to
    from public.toll_plazas p
    join public.toll_tariffs t on t.toll_plaza_id = p.id
    where p.is_active
      and t.tariff_status in ('active', 'future')
      and t.effective_from <= current_date
      and (t.effective_to is null or t.effective_to >= current_date)
    group by p.operator_key
  )
  select p.provider_key, p.provider_name, p.provider_status, p.coverage_status,
         coalesce(p.active_plaza_count, 0),
         coalesce(p.current_tariff_count, 0),
         coalesce(p.coordinate_coverage_percent, 0),
         coalesce(p.classification_coverage_percent, 0),
         p.route_matching_readiness,
         p.last_check_at, p.last_success_at, p.last_failure_at, p.last_error,
         p.next_expected_check_at, p.last_publication_effective_date, p.last_publication_title,
         p.scheduler_status, p.endpoint_url as source_url, p.coverage_notes,
         periods.current_effective_from,
         periods.current_effective_to
  from public.pricing_external_providers p
  left join current_periods periods on periods.operator_key = p.provider_key
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

comment on function public.ttaq_refresh_toll_provider_coverage() is
  'Recomputes toll provider health from actual active plaza, current tariff, coordinate, and equipment-class coverage so Complete cannot coexist with zero active plazas.';
