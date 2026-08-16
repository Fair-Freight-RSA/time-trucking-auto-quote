with coordinate_fixes(plaza_key, latitude, longitude, coordinate_confidence, coordinate_source, route_match_strategy, note) as (
  values
    ('n3tc-n3-tugela-east-ramp', null::numeric, null::numeric, 'review_required', 'Ramp coordinate is not independently verified; do not reuse Tugela mainline coordinate', 'coordinate_review_required', 'Prevents the Tugela East ramp tariff from being substituted when a route only crosses the Tugela mainline plaza.'),
    ('sanral-n1-grasmere-mainline', -26.4171100, 27.8807500, 'verified_map_source', 'Mapcarta/OpenStreetMap tollbooth node cross-check for Grasmere', 'mainline_geometry_threshold', 'Corrects the earlier coordinate that was too far from the N1 route geometry.'),
    ('sanral-n1-vaal-mainline', -26.8563900, 27.6352800, 'verified_map_source', 'N1 toll-plaza coordinate cross-check from public map gazette references/OpenStreetMap-derived listings', 'mainline_geometry_threshold', 'Corrects the earlier coordinate that was too far from the N1 route geometry.'),
    ('sanral-n1-verkeerdevlei-mainline', -28.7988900, 26.6905600, 'verified_map_source', 'N1 toll-plaza coordinate cross-check from public map gazette references/OpenStreetMap-derived listings', 'mainline_geometry_threshold', 'Corrects the earlier coordinate that was too far from the N1 route geometry.'),
    ('sanral-n1-huguenot-mainline', -33.7428000, 19.0197000, 'verified_map_source', 'N1 toll-plaza coordinate cross-check from public map gazette references/OpenStreetMap-derived listings', 'mainline_geometry_threshold', 'Uses the toll-plaza coordinate rather than the broader tunnel-route marker.'),
    ('sanral-n3-mariannhill-mainline', -29.8230200, 30.8027600, 'verified_map_source', 'Mapcarta/OpenStreetMap tollbooth node cross-check for Mariannhill Plaza', 'mainline_geometry_threshold', 'Corrects the earlier coordinate that did not match the N3 route geometry.')
)
update public.toll_plazas plaza
   set latitude = fixes.latitude,
       longitude = fixes.longitude,
       coordinate_confidence = fixes.coordinate_confidence,
       coordinate_source = fixes.coordinate_source,
       route_match_strategy = fixes.route_match_strategy,
       source_metadata = coalesce(plaza.source_metadata, '{}'::jsonb)
         || jsonb_build_object(
              'coordinate_correction_note', fixes.note,
              'coordinate_corrected_at', now(),
              'automatic_route_matching_enabled', fixes.coordinate_confidence in ('operator_published', 'verified_route_geometry', 'verified_map_source')
            ),
       updated_at = now()
  from coordinate_fixes fixes
 where plaza.plaza_key = fixes.plaza_key;

select public.ttaq_refresh_toll_provider_coverage();
