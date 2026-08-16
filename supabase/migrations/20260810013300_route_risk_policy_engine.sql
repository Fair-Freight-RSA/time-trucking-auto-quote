alter table public.route_risk_pricing_rules
  add column if not exists rule_description text,
  add column if not exists trigger_scope text not null default 'route_text',
  add column if not exists rule_type text not null default 'route_keyword',
  add column if not exists province text,
  add column if not exists route_number text,
  add column if not exists max_distance_km numeric(14, 2),
  add column if not exists priority integer not null default 100,
  add column if not exists effective_from date not null default current_date,
  add column if not exists effective_to date,
  add column if not exists criteria jsonb not null default '{}'::jsonb,
  add column if not exists geofence jsonb not null default '{}'::jsonb,
  add column if not exists corridor jsonb not null default '{}'::jsonb,
  add column if not exists stackable boolean not null default false,
  add column if not exists source_status text not null default 'time_trucking_configured_policy',
  add column if not exists management_notes text,
  add column if not exists rule_version integer not null default 1,
  add column if not exists created_by uuid references public.internal_users(id),
  add column if not exists updated_by uuid references public.internal_users(id),
  add constraint route_risk_rules_trigger_scope_check check (trigger_scope in ('origin', 'destination', 'either_endpoint', 'both_endpoints', 'route_traverses', 'route_corridor', 'minimum_distance', 'route_text', 'remote_zone', 'cross_border_corridor')),
  add constraint route_risk_rules_rule_type_check check (rule_type in ('origin_area', 'destination_area', 'route_corridor', 'geographic_zone', 'town_city', 'province', 'border_corridor', 'minimum_distance', 'road_route_identifier', 'remote_location', 'combined_criteria', 'route_keyword')),
  add constraint route_risk_rules_source_status_check check (source_status in ('time_trucking_configured_policy', 'draft', 'needs_review', 'inactive', 'external_advisory_only')),
  add constraint route_risk_rules_effective_period_check check (effective_to is null or effective_to >= effective_from);

create table if not exists public.route_risk_categories (
  id uuid primary key default gen_random_uuid(),
  pricing_profile_id uuid not null references public.pricing_profiles(id) on delete cascade,
  category_key text not null,
  display_name text not null,
  fixed_surcharge numeric(14, 2) not null default 0,
  surcharge_percent numeric(10, 4) not null default 0,
  severity_rank integer not null default 0,
  manager_review_required boolean not null default false,
  is_active boolean not null default true,
  effective_from date not null default current_date,
  effective_to date,
  notes text,
  created_by uuid references public.internal_users(id),
  updated_by uuid references public.internal_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (pricing_profile_id, category_key),
  constraint route_risk_categories_key_check check (category_key in ('normal', 'elevated', 'high', 'restricted_manual_review') or category_key ~ '^[a-z0-9_]+$'),
  constraint route_risk_categories_non_negative_check check (fixed_surcharge >= 0 and surcharge_percent >= 0),
  constraint route_risk_categories_effective_period_check check (effective_to is null or effective_to >= effective_from)
);

create table if not exists public.route_risk_overrides (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  pricing_calculation_id uuid references public.pricing_calculations(id) on delete set null,
  system_risk_category text,
  system_risk_amount numeric(14, 2),
  override_risk_category text,
  override_risk_amount numeric(14, 2) not null,
  override_reason text not null,
  override_payload jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  created_by uuid references public.internal_users(id),
  created_at timestamptz not null default now(),
  constraint route_risk_overrides_amount_check check (override_risk_amount >= 0),
  constraint route_risk_overrides_reason_check check (length(trim(override_reason)) >= 5)
);

create index if not exists ttaq_route_risk_categories_profile_idx on public.route_risk_categories(pricing_profile_id, is_active, severity_rank desc);
create index if not exists ttaq_route_risk_rules_policy_idx on public.route_risk_pricing_rules(pricing_profile_id, is_active, priority, effective_from, effective_to);
create index if not exists ttaq_route_risk_overrides_quote_idx on public.route_risk_overrides(quote_request_id, is_active, created_at desc);

drop trigger if exists ttaq_route_risk_categories_touch_updated_at on public.route_risk_categories;
create trigger ttaq_route_risk_categories_touch_updated_at
before update on public.route_risk_categories
for each row execute function public.ttaq_touch_updated_at();

alter table public.route_risk_categories enable row level security;
alter table public.route_risk_overrides enable row level security;

drop policy if exists "Internal users read route risk categories" on public.route_risk_categories;
create policy "Internal users read route risk categories" on public.route_risk_categories for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

drop policy if exists "Owner manages route risk categories" on public.route_risk_categories;
create policy "Owner manages route risk categories" on public.route_risk_categories for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

drop policy if exists "Internal users read route risk overrides" on public.route_risk_overrides;
create policy "Internal users read route risk overrides" on public.route_risk_overrides for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

drop policy if exists "Pricing managers write route risk overrides" on public.route_risk_overrides;
create policy "Pricing managers write route risk overrides" on public.route_risk_overrides for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules') or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

insert into public.route_risk_categories (
  pricing_profile_id, category_key, display_name, fixed_surcharge, surcharge_percent, severity_rank, manager_review_required, notes
)
select id, category_key, display_name, fixed_surcharge, surcharge_percent, severity_rank, manager_review_required, notes
from public.pricing_profiles
cross join (
  values
    ('normal', 'Normal', 0::numeric, 0::numeric, 0, false, 'Default category only. No Time Trucking risk area is implied.'),
    ('elevated', 'Elevated', 0::numeric, 0::numeric, 10, false, 'Configure only after Time Trucking approves a commercial surcharge.'),
    ('high', 'High', 0::numeric, 0::numeric, 20, true, 'Configure only after Time Trucking approves a commercial surcharge.'),
    ('restricted_manual_review', 'Restricted / manual review', 0::numeric, 0::numeric, 30, true, 'Manual review category; no invented location assignment.')
) seed(category_key, display_name, fixed_surcharge, surcharge_percent, severity_rank, manager_review_required, notes)
on conflict (pricing_profile_id, category_key) do nothing;

update public.route_risk_pricing_rules
   set source_status = case when is_active then 'time_trucking_configured_policy' else 'inactive' end,
       criteria = coalesce(criteria, '{}'::jsonb) || jsonb_build_object(
         'legacy_route_keyword', route_keyword,
         'legacy_origin_keyword', origin_keyword,
         'legacy_destination_keyword', destination_keyword
       ),
       rule_description = coalesce(rule_description, notes, 'Legacy Time Trucking route-risk rule migrated into policy model.'),
       trigger_scope = case
         when origin_keyword is not null and destination_keyword is not null then 'both_endpoints'
         when origin_keyword is not null then 'origin'
         when destination_keyword is not null then 'destination'
         when route_keyword is not null then 'route_text'
         when min_distance_km is not null then 'minimum_distance'
         else trigger_scope
       end,
       rule_type = case
         when min_distance_km is not null and route_keyword is null and origin_keyword is null and destination_keyword is null then 'minimum_distance'
         else rule_type
       end
 where criteria = '{}'::jsonb
    or rule_description is null;

create or replace function public.ttaq_degrees_distance_km(lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric)
returns numeric
language sql
immutable
as $$
  select 6371 * 2 * asin(sqrt(
    power(sin(radians(($3 - $1) / 2)), 2)
    + cos(radians($1)) * cos(radians($3)) * power(sin(radians(($4 - $2) / 2)), 2)
  ));
$$;

create or replace function public.ttaq_point_in_polygon(point_lat numeric, point_lon numeric, polygon jsonb)
returns boolean
language plpgsql
immutable
as $$
declare
  inside boolean := false;
  point_count integer := jsonb_array_length(coalesce(polygon, '[]'::jsonb));
  i integer := 0;
  j integer := point_count - 1;
  yi numeric;
  xi numeric;
  yj numeric;
  xj numeric;
begin
  if point_count < 3 then
    return false;
  end if;

  while i < point_count loop
    yi := (polygon->i->>'lat')::numeric;
    xi := (polygon->i->>'lng')::numeric;
    yj := (polygon->j->>'lat')::numeric;
    xj := (polygon->j->>'lng')::numeric;
    if ((yi > point_lat) <> (yj > point_lat))
       and (point_lon < (xj - xi) * (point_lat - yi) / nullif(yj - yi, 0) + xi) then
      inside := not inside;
    end if;
    j := i;
    i := i + 1;
  end loop;
  return inside;
exception when others then
  return false;
end;
$$;

create or replace function public.ttaq_route_points(route_payload jsonb)
returns table(point_index integer, latitude numeric, longitude numeric)
language sql
stable
as $$
  select (row_number() over ())::integer,
         nullif(value->>'latitude', '')::numeric,
         nullif(value->>'longitude', '')::numeric
  from jsonb_array_elements(coalesce(route_payload->'route_path_points', '[]'::jsonb)) value
  where value ? 'latitude' and value ? 'longitude';
$$;

create or replace function public.ttaq_evaluate_route_risk_policy(
  target_quote_request_id uuid,
  target_route_estimate_id uuid,
  base_cost_value numeric,
  pricing_date date default current_date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_id uuid;
  request_record public.quote_requests%rowtype;
  route_record public.route_estimates%rowtype;
  route_payload jsonb := '{}'::jsonb;
  route_text text := '';
  origin_text text := '';
  destination_text text := '';
  route_point_count integer := 0;
  configured_rule_count integer := 0;
  matched_rules jsonb := '[]'::jsonb;
  controlling_rule jsonb := null;
  category_record public.route_risk_categories%rowtype;
  surcharge_amount numeric := 0;
  override_record public.route_risk_overrides%rowtype;
  requires_review boolean := false;
begin
  profile_id := public.ttaq_active_pricing_profile();

  select * into request_record
  from public.quote_requests
  where id = target_quote_request_id;

  select * into route_record
  from public.route_estimates
  where id = target_route_estimate_id;

  route_payload := coalesce(route_record.provider_response, '{}'::jsonb);
  origin_text := lower(coalesce(route_record.origin_address, request_record.collection_address, ''));
  destination_text := lower(coalesce(route_record.destination_address, request_record.delivery_address, ''));
  route_text := lower(concat_ws(' ', origin_text, destination_text, route_record.route_notes, route_payload->>'road_summary', route_payload->>'warnings'));

  select count(*) into route_point_count
  from public.ttaq_route_points(route_payload);

  select count(*) into configured_rule_count
  from public.route_risk_pricing_rules
  where pricing_profile_id = profile_id
    and is_active
    and source_status = 'time_trucking_configured_policy'
    and effective_from <= pricing_date
    and (effective_to is null or effective_to >= pricing_date);

  if configured_rule_count = 0 then
    return jsonb_build_object(
      'amount', 0,
      'source', 'Time Trucking configured policy',
      'status', 'no_configured_policy_match',
      'category', 'normal',
      'requires_review', false,
      'reason', 'No Time Trucking risk rule configured/matched.',
      'matched_rules', '[]'::jsonb,
      'external_route_signals', jsonb_build_object('route_geometry_available', route_point_count > 0, 'route_provider_status', route_record.provider_status)
    );
  end if;

  with active_rules as (
    select r.*, coalesce(c.category_key, r.risk_level, 'normal') as category_key,
           coalesce(c.display_name, initcap(coalesce(r.risk_level, 'normal'))) as category_display_name,
           coalesce(c.fixed_surcharge, r.fixed_surcharge, 0) as category_fixed_surcharge,
           coalesce(c.surcharge_percent, r.surcharge_percent, 0) as category_surcharge_percent,
           coalesce(c.severity_rank, case r.risk_level when 'restricted_manual_review' then 30 when 'high' then 20 when 'elevated' then 10 else 0 end) as severity_rank,
           coalesce(c.manager_review_required, r.manager_review_required, false) as category_review_required
    from public.route_risk_pricing_rules r
    left join public.route_risk_categories c
      on c.pricing_profile_id = r.pricing_profile_id
     and c.category_key = coalesce(nullif(r.risk_level, ''), 'normal')
     and c.is_active
     and c.effective_from <= pricing_date
     and (c.effective_to is null or c.effective_to >= pricing_date)
    where r.pricing_profile_id = profile_id
      and r.is_active
      and r.source_status = 'time_trucking_configured_policy'
      and r.effective_from <= pricing_date
      and (r.effective_to is null or r.effective_to >= pricing_date)
      and (r.min_distance_km is null or coalesce(route_record.total_distance_km, route_record.manual_distance_km, 0) >= r.min_distance_km)
      and (r.max_distance_km is null or coalesce(route_record.total_distance_km, route_record.manual_distance_km, 0) <= r.max_distance_km)
      and (r.route_number is null or route_text like '%' || lower(r.route_number) || '%')
      and (r.province is null or route_text like '%' || lower(r.province) || '%')
      and (r.origin_keyword is null or origin_text like '%' || lower(r.origin_keyword) || '%')
      and (r.destination_keyword is null or destination_text like '%' || lower(r.destination_keyword) || '%')
      and (r.route_keyword is null or route_text like '%' || lower(r.route_keyword) || '%')
  ),
  rule_matches as (
    select r.*,
           case
             when r.trigger_scope in ('route_traverses', 'remote_zone', 'route_corridor') and r.geofence ? 'radius_km' then exists (
               select 1
               from public.ttaq_route_points(route_payload) p
               where public.ttaq_degrees_distance_km(p.latitude, p.longitude, (r.geofence->>'lat')::numeric, (r.geofence->>'lng')::numeric) <= (r.geofence->>'radius_km')::numeric
             )
             when r.trigger_scope in ('origin', 'either_endpoint', 'both_endpoints') and r.geofence ? 'radius_km' then public.ttaq_degrees_distance_km(
               coalesce((route_payload #>> '{stops,0,latitude}')::numeric, 999),
               coalesce((route_payload #>> '{stops,0,longitude}')::numeric, 999),
               (r.geofence->>'lat')::numeric,
               (r.geofence->>'lng')::numeric
             ) <= (r.geofence->>'radius_km')::numeric
             when r.trigger_scope in ('destination', 'either_endpoint', 'both_endpoints') and r.geofence ? 'radius_km' then exists (
               select 1
               from jsonb_array_elements(coalesce(route_payload->'stops', '[]'::jsonb)) stop
               where (stop->>'stop_order')::integer = jsonb_array_length(coalesce(route_payload->'stops', '[]'::jsonb))
                 and public.ttaq_degrees_distance_km((stop->>'latitude')::numeric, (stop->>'longitude')::numeric, (r.geofence->>'lat')::numeric, (r.geofence->>'lng')::numeric) <= (r.geofence->>'radius_km')::numeric
             )
             when r.geofence ? 'polygon' and r.trigger_scope in ('route_traverses', 'remote_zone', 'route_corridor') then exists (
               select 1
               from public.ttaq_route_points(route_payload) p
               where public.ttaq_point_in_polygon(p.latitude, p.longitude, r.geofence->'polygon')
             )
             when r.trigger_scope in ('minimum_distance', 'route_text') then true
             when r.rule_type in ('route_keyword', 'road_route_identifier', 'province', 'town_city', 'combined_criteria') then true
             else false
           end as matched,
           case
             when r.geofence <> '{}'::jsonb and route_point_count = 0 then true
             else false
           end as geometry_required_unavailable
    from active_rules r
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'rule_id', id,
           'rule_name', rule_name,
           'rule_version', rule_version,
           'category', category_key,
           'trigger_scope', trigger_scope,
           'rule_type', rule_type,
           'priority', priority,
           'severity_rank', severity_rank,
           'fixed_surcharge', coalesce(nullif(fixed_surcharge, 0), category_fixed_surcharge, 0),
           'surcharge_percent', coalesce(nullif(surcharge_percent, 0), category_surcharge_percent, 0),
           'manager_review_required', manager_review_required or category_review_required,
           'source', 'Time Trucking configured policy',
           'matching_reason', case
             when geometry_required_unavailable then 'Route risk could not be fully evaluated because geometry is unavailable.'
             else 'Configured route-risk rule matched the route/request evidence.'
           end,
           'route_evidence', jsonb_build_object(
             'route_geometry_available', route_point_count > 0,
             'route_distance_km', coalesce(route_record.total_distance_km, route_record.manual_distance_km, 0),
             'trigger_scope', trigger_scope,
             'geofence', geofence,
             'corridor', corridor
           )
         ) order by priority asc, severity_rank desc, created_at desc), '[]'::jsonb)
    into matched_rules
  from rule_matches
  where matched or geometry_required_unavailable;

  if matched_rules = '[]'::jsonb then
    return jsonb_build_object(
      'amount', 0,
      'source', 'Time Trucking configured policy',
      'status', 'no_risk_match',
      'category', 'normal',
      'requires_review', false,
      'reason', 'R0 because no active Time Trucking route-risk rule matched.',
      'matched_rules', '[]'::jsonb,
      'external_route_signals', jsonb_build_object('route_geometry_available', route_point_count > 0, 'route_provider_status', route_record.provider_status)
    );
  end if;

  select value into controlling_rule
  from jsonb_array_elements(matched_rules) value
  order by (value->>'priority')::integer asc, (value->>'severity_rank')::integer desc
  limit 1;

  if controlling_rule->>'matching_reason' = 'Route risk could not be fully evaluated because geometry is unavailable.' then
    return jsonb_build_object(
      'amount', 0,
      'source', 'Time Trucking configured policy',
      'status', 'unknown_geometry_required',
      'category', 'review_required',
      'requires_review', true,
      'reason', 'Route risk could not be fully evaluated.',
      'matched_rules', matched_rules,
      'controlling_rule', controlling_rule
    );
  end if;

  surcharge_amount := round(
    coalesce((controlling_rule->>'fixed_surcharge')::numeric, 0)
    + (coalesce(base_cost_value, 0) * (coalesce((controlling_rule->>'surcharge_percent')::numeric, 0) / 100)),
    2
  );
  requires_review := coalesce((controlling_rule->>'manager_review_required')::boolean, false);

  select * into override_record
  from public.route_risk_overrides
  where quote_request_id = target_quote_request_id
    and is_active
  order by created_at desc
  limit 1;

  if override_record.id is not null then
    return jsonb_build_object(
      'amount', override_record.override_risk_amount,
      'source', 'Management override',
      'status', 'manual_override',
      'category', coalesce(override_record.override_risk_category, controlling_rule->>'category'),
      'requires_review', false,
      'system_amount', surcharge_amount,
      'override_id', override_record.id,
      'override_reason', override_record.override_reason,
      'matched_rules', matched_rules,
      'controlling_rule', controlling_rule
    );
  end if;

  return jsonb_build_object(
    'amount', surcharge_amount,
    'source', 'Time Trucking configured policy',
    'status', 'automatic_configured_policy',
    'category', controlling_rule->>'category',
    'requires_review', requires_review,
    'fixed_surcharge', (controlling_rule->>'fixed_surcharge')::numeric,
    'surcharge_percent', (controlling_rule->>'surcharge_percent')::numeric,
    'matched_rules', matched_rules,
    'controlling_rule', controlling_rule,
    'reason', 'Highest-priority applicable Time Trucking route-risk rule controls pricing. Surcharges are not stacked unless a future rule explicitly implements stacking.'
  );
end;
$$;

grant execute on function public.ttaq_evaluate_route_risk_policy(uuid, uuid, numeric, date) to authenticated;

create or replace function public.ttaq_apply_route_risk_policy_enrichment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  route_record public.route_estimates%rowtype;
  request_record public.quote_requests%rowtype;
  risk_result jsonb := '{}'::jsonb;
  old_risk_amount numeric := 0;
  new_risk_amount numeric := 0;
  delta_amount numeric := 0;
  adjusted_subtotal numeric;
  adjusted_profit numeric;
  adjusted_vat numeric;
  adjusted_total numeric;
  vat_rate numeric := 0;
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

  risk_result := public.ttaq_evaluate_route_risk_policy(
    new.quote_request_id,
    route_record.id,
    coalesce(new.dynamic_outputs->>'base_cost_before_seasonal', new.subtotal::text)::numeric,
    coalesce(request_record.collection_date, current_date)
  );

  if risk_result->>'status' in ('automatic_configured_policy', 'no_risk_match', 'no_configured_policy_match', 'manual_override') then
    old_risk_amount := coalesce(new.route_risk_amount, 0);
    new_risk_amount := coalesce((risk_result->>'amount')::numeric, 0);
    delta_amount := new_risk_amount - old_risk_amount;
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
       set route_risk_amount = new_risk_amount,
           subtotal = adjusted_subtotal,
           profit_amount = adjusted_profit,
           vat_amount = adjusted_vat,
           grand_total = adjusted_total,
           recommended_selling_price = adjusted_total,
           dynamic_outputs = coalesce(dynamic_outputs, '{}'::jsonb)
             || jsonb_build_object(
               'route_risk_amount', new_risk_amount,
               'calculated_cost_before_profit_vat', adjusted_subtotal,
               'profit_amount', adjusted_profit,
               'vat_amount', adjusted_vat,
               'grand_total', adjusted_total,
               'route_risk_pricing_delta', delta_amount
             ),
           pricing_source_snapshot = coalesce(pricing_source_snapshot, '{}'::jsonb)
             || jsonb_build_object('route_risk', risk_result),
           dynamic_inputs = coalesce(dynamic_inputs, '{}'::jsonb)
             || jsonb_build_object('route_risk', risk_result),
           automation_status = coalesce(automation_status, '{}'::jsonb)
             || jsonb_build_object(
               'route_risk_requires_review', coalesce((risk_result->>'requires_review')::boolean, false),
               'route_risk_status', risk_result->>'status',
               'route_risk_reason', risk_result->>'reason'
             ),
           manager_review_required = coalesce(manager_review_required, false) or coalesce((risk_result->>'requires_review')::boolean, false)
     where id = new.id;

    update public.pricing_breakdowns
       set quantity = coalesce(new.dynamic_outputs->>'base_cost_before_seasonal', new.subtotal::text)::numeric,
           unit_rate = coalesce((risk_result->>'surcharge_percent')::numeric, 0),
           amount = new_risk_amount,
           explanation = case
             when risk_result->>'status' in ('no_risk_match', 'no_configured_policy_match') then risk_result->>'reason'
             when risk_result->>'status' = 'manual_override' then 'Management override applied to Time Trucking route-risk policy result.'
             else 'Time Trucking configured route-risk policy selected the controlling rule and surcharge.'
           end
     where pricing_calculation_id = new.id
       and line_key = 'route_risk';
  else
    update public.pricing_calculations
       set pricing_source_snapshot = coalesce(pricing_source_snapshot, '{}'::jsonb)
             || jsonb_build_object('route_risk', risk_result),
           automation_status = coalesce(automation_status, '{}'::jsonb)
             || jsonb_build_object(
               'route_risk_requires_review', true,
               'route_risk_status', risk_result->>'status',
               'route_risk_reason', risk_result->>'reason'
             ),
           manager_review_required = true
     where id = new.id;
  end if;

  return new;
end;
$$;

drop trigger if exists ttaq_apply_route_risk_policy_enrichment on public.pricing_calculations;
create trigger ttaq_apply_route_risk_policy_enrichment
after insert on public.pricing_calculations
for each row execute function public.ttaq_apply_route_risk_policy_enrichment();

create or replace function public.ttaq_route_risk_policy_summary()
returns jsonb
language sql
security definer
set search_path = public
as $$
  with profile as (
    select public.ttaq_active_pricing_profile() as id
  )
  select jsonb_build_object(
    'categories', coalesce((
      select jsonb_agg(to_jsonb(c) order by c.severity_rank, c.display_name)
      from public.route_risk_categories c, profile
      where c.pricing_profile_id = profile.id
    ), '[]'::jsonb),
    'rules', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.is_active desc, r.priority asc, r.updated_at desc)
      from public.route_risk_pricing_rules r, profile
      where r.pricing_profile_id = profile.id
    ), '[]'::jsonb)
  );
$$;

grant execute on function public.ttaq_route_risk_policy_summary() to authenticated;

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
  where auth_user_id = auth.uid()
  limit 1;

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
