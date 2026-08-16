alter table public.toll_plazas
  alter column latitude drop not null,
  alter column longitude drop not null;

alter table public.toll_plazas
  drop constraint if exists toll_plazas_coordinate_presence_check,
  add constraint toll_plazas_coordinate_presence_check
    check (
      (latitude is not null and longitude is not null)
      or coordinate_confidence = 'review_required'
    );

alter table public.toll_tariffs
  drop constraint if exists toll_tariffs_effective_from_required_check,
  add constraint toll_tariffs_effective_from_required_check
    check (effective_from is not null);

update public.toll_tariffs tariff
   set source_provider = 'za_n3tc_official_tolls_stale_webpage_superseded',
       tariff_status = 'superseded',
       source_metadata = coalesce(tariff.source_metadata, '{}'::jsonb)
         || jsonb_build_object(
              'superseded_reason', 'N3TC public toll-tariffs HTML exposed stale 2024-style values and inconsistent trip-total notes; corrected rows are seeded from the 2026 SANRAL tariff poster/Government Gazette Nos. 54087 and 54088.',
              'superseded_at', now()
            ),
       updated_at = now()
  from public.toll_plazas plaza
 where tariff.toll_plaza_id = plaza.id
   and plaza.plaza_key in (
     'n3tc-n3-de-hoek-mainline',
     'n3tc-n3-wilge-mainline',
     'n3tc-n3-tugela-mainline',
     'n3tc-n3-mooi-mainline',
     'n3tc-n3-tugela-east-ramp',
     'n3tc-n3-bergville-ramp',
     'n3tc-n3-mooi-treverton-ramp',
     'n3tc-n3-mooi-north-ramp',
     'n3tc-n3-mooi-south-ramp'
   )
   and tariff.effective_from = date '2026-03-01'
   and tariff.source_provider = 'za_n3tc_official_tolls';

with n3tc_verified(plaza_key, plaza_name, road_route, operator_key, latitude, longitude, plaza_type, class_1_rate, class_2_rate, class_3_rate, class_4_rate, coordinate_confidence, coordinate_source, route_match_strategy) as (
  values
    ('n3tc-n3-de-hoek-mainline', 'De Hoek Mainline Plaza', 'N3', 'za_n3tc_official_tolls', -26.7256385, 28.4147685, 'mainline', 67.00, 105.00, 160.00, 230.00, 'verified_route_geometry', 'Google Routes N3 geometry / published N3 toll section evidence', 'mainline_geometry_threshold'),
    ('n3tc-n3-wilge-mainline', 'Wilge Mainline Plaza', 'N3', 'za_n3tc_official_tolls', -27.1008650, 28.6648159, 'mainline', 94.00, 161.00, 215.00, 304.00, 'verified_route_geometry', 'Google Routes N3 geometry / published N3 toll section evidence', 'mainline_geometry_threshold'),
    ('n3tc-n3-tugela-mainline', 'Tugela Mainline Plaza', 'N3', 'za_n3tc_official_tolls', -28.4480585, 29.5313636, 'mainline', 100.00, 165.00, 260.00, 359.00, 'verified_route_geometry', 'Google Routes N3 geometry / published N3 toll section evidence', 'mainline_geometry_threshold'),
    ('n3tc-n3-mooi-mainline', 'Mooi Mainline Plaza', 'N3', 'za_n3tc_official_tolls', -29.1991016, 29.9984886, 'mainline', 70.00, 171.00, 240.00, 324.00, 'verified_route_geometry', 'Google Routes N3 geometry / published N3 toll section evidence', 'mainline_geometry_threshold'),
    ('n3tc-n3-tugela-east-ramp', 'Tugela East Ramp Plaza', 'N3', 'za_n3tc_official_tolls', -28.4480585, 29.5313636, 'ramp', 62.00, 102.00, 152.00, 211.00, 'verified_route_geometry', 'Google Routes N3 geometry / published N3 toll section evidence', 'strict_ramp_geometry_threshold'),
    ('n3tc-n3-bergville-ramp', 'Bergville Ramp Plaza', 'N3', 'za_n3tc_official_tolls', null, null, 'ramp', 30.00, 35.00, 65.00, 100.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('n3tc-n3-mooi-treverton-ramp', 'Mooi Treverton Ramp Plaza', 'N3', 'za_n3tc_official_tolls', null, null, 'ramp', 21.00, 51.00, 72.00, 97.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('n3tc-n3-mooi-north-ramp', 'Mooi North Ramp Plaza', 'N3', 'za_n3tc_official_tolls', null, null, 'ramp', 21.00, 51.00, 72.00, 97.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('n3tc-n3-mooi-south-ramp', 'Mooi South Ramp Plaza', 'N3', 'za_n3tc_official_tolls', null, null, 'ramp', 49.00, 119.00, 168.00, 227.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required')
),
sanral_verified(plaza_key, plaza_name, road_route, operator_key, latitude, longitude, plaza_type, class_1_rate, class_2_rate, class_3_rate, class_4_rate, coordinate_confidence, coordinate_source, route_match_strategy) as (
  values
    ('sanral-n1-huguenot-mainline', 'Huguenot Mainline Plaza', 'N1', 'za_sanral_official_tolls', -33.7414000, 19.1058000, 'mainline', 54.50, 151.00, 236.00, 383.00, 'verified_map_source', 'Tripcost/OpenStreetMap cross-check for Huguenot Tunnel toll plaza', 'mainline_geometry_threshold'),
    ('sanral-n1-vaal-mainline', 'Vaal Mainline Plaza', 'N1', 'za_sanral_official_tolls', -26.7964000, 27.8389000, 'mainline', 91.50, 172.00, 207.00, 275.00, 'verified_map_source', 'Tripcost/OpenStreetMap cross-check for Vaal/Kroonvaal toll plaza', 'mainline_geometry_threshold'),
    ('sanral-n1-grasmere-mainline', 'Grasmere Mainline Plaza', 'N1', 'za_sanral_official_tolls', -26.4194000, 27.8447000, 'mainline', 27.50, 82.00, 96.00, 126.00, 'verified_map_source', 'Tripcost/OpenStreetMap cross-check for Grasmere toll plaza', 'mainline_geometry_threshold'),
    ('sanral-n1-grasmere-ramp-north', 'Grasmere North Ramp Plaza', 'N1', 'za_sanral_official_tolls', null, null, 'ramp', 14.00, 41.00, 48.00, 63.00, 'review_required', 'Ramp coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n1-grasmere-ramp-south', 'Grasmere South Ramp Plaza', 'N1', 'za_sanral_official_tolls', null, null, 'ramp', 14.00, 41.00, 48.00, 63.00, 'review_required', 'Ramp coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n1-verkeerdevlei-mainline', 'Verkeerdevlei Mainline Plaza', 'N1', 'za_sanral_official_tolls', -28.7833000, 26.7333000, 'mainline', 78.50, 157.00, 236.00, 331.00, 'verified_map_source', 'Tripcost/OpenStreetMap cross-check for Verkeerdevlei toll plaza', 'mainline_geometry_threshold'),
    ('sanral-n1-kranskop-mainline', 'Kranskop Mainline Plaza', 'N1', 'za_sanral_official_tolls', null, null, 'mainline', 61.50, 157.00, 210.00, 257.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n1-kranskop-ramp', 'Kranskop Ramp Plaza', 'N1', 'za_sanral_official_tolls', null, null, 'ramp', 17.00, 46.00, 54.00, 81.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n1-nyl-mainline', 'Nyl Mainline Plaza', 'N1', 'za_sanral_official_tolls', null, null, 'mainline', 79.50, 149.00, 180.00, 241.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n1-nyl-ramp', 'Nyl Ramp Plaza', 'N1', 'za_sanral_official_tolls', null, null, 'ramp', 24.50, 46.00, 54.00, 69.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n1-sebetiela-ramp', 'Sebetiela Ramp Plaza', 'N1', 'za_sanral_official_tolls', null, null, 'ramp', 24.50, 46.00, 58.00, 77.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n1-capricorn-mainline', 'Capricorn Mainline Plaza', 'N1', 'za_sanral_official_tolls', null, null, 'mainline', 63.50, 175.00, 205.00, 256.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n1-baobab-mainline', 'Baobab Mainline Plaza', 'N1', 'za_sanral_official_tolls', null, null, 'mainline', 61.50, 168.00, 231.00, 278.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-tsitsikamma-mainline-ramp', 'Tsitsikamma Mainline/Ramp Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'mainline', 73.00, 183.00, 438.00, 619.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-izotsha-ramp', 'Izotsha Ramp Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'ramp', 12.50, 23.00, 31.00, 54.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-oribi-mainline', 'Oribi Mainline Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'mainline', 41.00, 73.00, 100.00, 162.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-oribi-ramp-south', 'Oribi South Ramp Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'ramp', 18.50, 34.00, 46.00, 73.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-oribi-ramp-north', 'Oribi North Ramp Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'ramp', 22.00, 38.00, 54.00, 100.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-umtentweni-ramp', 'Umtentweni Ramp Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'ramp', 17.50, 31.00, 42.00, 69.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-king-shaka-airport-ramp', 'King Shaka Airport Ramp Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'ramp', 8.50, 17.00, 26.00, 34.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-othongathi-mainline', 'oThongathi Mainline Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'mainline', 15.50, 32.00, 42.00, 62.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-othongathi-ramp', 'oThongathi Ramp Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'ramp', 7.50, 17.00, 21.00, 31.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-mvoti-mainline', 'Mvoti Mainline Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'mainline', 18.50, 52.00, 70.00, 104.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-mandini-ramp', 'Mandini Ramp Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'ramp', 10.00, 19.00, 23.00, 31.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-dokodweni-ramp', 'Dokodweni Ramp Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'ramp', 27.00, 53.00, 62.00, 84.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-mtunzini-mainline', 'Mtunzini Mainline Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'mainline', 63.50, 122.00, 146.00, 217.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-mtunzini-ramp-south', 'Mtunzini South Ramp Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'ramp', 53.00, 99.00, 119.00, 172.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n2-mtunzini-ramp-north', 'Mtunzini North Ramp Plaza', 'N2', 'za_sanral_official_tolls', null, null, 'ramp', 11.50, 23.00, 27.00, 45.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n3-mariannhill-mainline', 'Mariannhill Mainline Plaza', 'N3', 'za_sanral_official_tolls', -29.8167000, 30.8400000, 'mainline', 16.50, 30.00, 37.00, 57.00, 'verified_map_source', 'Tripcost/OpenStreetMap cross-check for Mariannhill toll plaza', 'mainline_geometry_threshold'),
    ('sanral-n4-pelindaba-mainline', 'Pelindaba Mainline Plaza', 'N4', 'za_sanral_official_tolls', null, null, 'mainline', 8.00, 15.00, 21.00, 27.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n4-quagga-mainline', 'Quagga Mainline Plaza', 'N4', 'za_sanral_official_tolls', null, null, 'mainline', 6.50, 11.00, 16.00, 21.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n17-gosforth-mainline', 'Gosforth Mainline Plaza', 'N17', 'za_sanral_official_tolls', null, null, 'mainline', 17.00, 46.00, 50.00, 69.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n17-gosforth-ramp-west', 'Gosforth West Ramp Plaza', 'N17', 'za_sanral_official_tolls', null, null, 'ramp', 9.50, 19.00, 25.00, 33.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n17-gosforth-ramp-east', 'Gosforth East Ramp Plaza', 'N17', 'za_sanral_official_tolls', null, null, 'ramp', 7.50, 29.00, 31.00, 42.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n17-dalpark-mainline', 'Dalpark Mainline Plaza', 'N17', 'za_sanral_official_tolls', null, null, 'mainline', 15.50, 32.00, 42.00, 58.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n17-denne-ramp', 'Denne Ramp Plaza', 'N17', 'za_sanral_official_tolls', null, null, 'ramp', 13.50, 27.00, 35.00, 46.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n17-leandra-mainline', 'Leandra Mainline Plaza', 'N17', 'za_sanral_official_tolls', null, null, 'mainline', 50.50, 127.00, 190.00, 253.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n17-leandra-ramp', 'Leandra Ramp Plaza', 'N17', 'za_sanral_official_tolls', null, null, 'ramp', 30.50, 77.00, 113.00, 152.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n17-trichardt-mainline', 'Trichardt Mainline Plaza', 'N17', 'za_sanral_official_tolls', null, null, 'mainline', 25.00, 63.00, 96.00, 127.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-n17-ermelo-mainline', 'Ermelo Mainline Plaza', 'N17', 'za_sanral_official_tolls', null, null, 'mainline', 45.00, 114.00, 170.00, 226.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required'),
    ('sanral-r30-brandfort-mainline', 'Brandfort Mainline Plaza', 'R30/R730/R34', 'za_sanral_official_tolls', null, null, 'mainline', 62.50, 125.00, 188.00, 265.00, 'review_required', 'Coordinate not sufficiently verified for automatic route matching', 'coordinate_review_required')
),
all_rows as (
  select *, 'https://www.n3tc.co.za/wp-content/uploads/2026/02/SANRAL-Toll-Tariff-A3-Poster-2026.pdf' as source_url,
         'SANRAL toll tariffs and discounts applicable to conventional toll plazas, effective 1 March 2026; Government Gazette Nos. 54087 and 54088 published 5 February 2026' as source_publication,
         date '2026-02-05' as publication_date
  from n3tc_verified
  union all
  select *, 'https://www.n3tc.co.za/wp-content/uploads/2026/02/SANRAL-Toll-Tariff-A3-Poster-2026.pdf',
         'SANRAL toll tariffs and discounts applicable to conventional toll plazas, effective 1 March 2026; Government Gazette Nos. 54087 and 54088 published 5 February 2026',
         date '2026-02-05'
  from sanral_verified
),
upserted_plazas as (
  insert into public.toll_plazas (
    plaza_key, plaza_name, road_route, operator_key, latitude, longitude, plaza_type,
    source_url, coordinate_source, coordinate_confidence, route_match_strategy, source_metadata, is_active
  )
  select plaza_key, plaza_name, road_route, operator_key, latitude, longitude, plaza_type,
         source_url, coordinate_source, coordinate_confidence, route_match_strategy,
         jsonb_build_object(
           'tariff_source_url', source_url,
           'source_publication', source_publication,
           'publication_date', publication_date,
           'coordinate_auto_matching_enabled', coordinate_confidence in ('operator_published', 'verified_route_geometry', 'verified_map_source'),
           'coordinate_review_note', case when coordinate_confidence = 'review_required' then 'Tariff is loaded for review/reference, but this plaza is excluded from automatic route matching until a reliable coordinate source is approved.' else 'Coordinate source is considered reliable enough for automatic route matching.' end
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
select plaza.id, row.class_1_rate, row.class_2_rate, row.class_3_rate, row.class_4_rate,
       date '2026-03-01', null, row.operator_key, row.source_publication, row.source_url,
       jsonb_build_object(
         'currency', 'ZAR',
         'vat_included', true,
         'publication_date', row.publication_date,
         'tariff_authority', 'Government Gazette Nos. 54087 and 54088 / SANRAL conventional toll tariff poster',
         'coordinate_confidence', row.coordinate_confidence
       ),
       true,
       case when current_date < date '2026-03-01' then 'future' else 'active' end
from all_rows row
join public.toll_plazas plaza on plaza.plaza_key = row.plaza_key
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

create unique index if not exists ttaq_toll_tariffs_one_active_source_per_effective
  on public.toll_tariffs(toll_plaza_id, effective_from)
  where tariff_status in ('active', 'future');

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
           when coalesce(counts.active_plaza_count, 0) > 0
            and coalesce(counts.current_tariff_count, 0) >= coalesce(counts.active_plaza_count, 0)
            and coalesce((select classification_coverage_percent from classification), 0) > 0
             then 'complete'
           when coalesce(counts.active_plaza_count, 0) > 0 then 'partial'
           else 'needs_review'
         end,
         provider_status = case
           when coalesce(counts.active_plaza_count, 0) > 0
            and coalesce(counts.current_tariff_count, 0) >= coalesce(counts.active_plaza_count, 0)
            and coalesce((select classification_coverage_percent from classification), 0) > 0
             then 'complete'
           when coalesce(counts.active_plaza_count, 0) > 0 then 'partial'
           else 'needs_review'
         end,
         route_matching_readiness = case
           when coalesce(counts.active_plaza_count, 0) > 0 and coalesce(counts.coordinate_ready_count, 0) > 0
             then 'geometry_matching_ready_for_verified_plazas'
           when coalesce(counts.active_plaza_count, 0) > 0
             then 'review_required_missing_coordinates'
           else 'review_required_no_active_plazas'
         end,
         coverage_notes = case
           when coalesce(counts.active_plaza_count, 0) > 0
            and coalesce(counts.current_tariff_count, 0) >= coalesce(counts.active_plaza_count, 0)
            and coalesce(counts.coordinate_ready_count, 0) >= coalesce(counts.active_plaza_count, 0)
             then 'Complete for loaded official 2026 plaza/tariff rows with route-ready coordinates and Class 1-4 equipment classification coverage.'
           when coalesce(counts.active_plaza_count, 0) > 0
            and coalesce(counts.current_tariff_count, 0) >= coalesce(counts.active_plaza_count, 0)
             then 'Complete tariff catalogue for loaded official 2026 rows. Automatic route matching is enabled only for plazas with verified coordinates; coordinate-review rows are stored for review/reference and excluded from automatic matching.'
           when coalesce(counts.active_plaza_count, 0) > 0 then 'Partial: plaza rows exist but tariff or classification coverage is incomplete.'
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

comment on function public.ttaq_refresh_toll_provider_coverage() is
  'Recomputes toll provider health from active plaza, current tariff, coordinate, and equipment-class coverage. Complete cannot coexist with zero active plazas; coordinate-review rows are excluded from automatic route matching by the Edge Function.';
