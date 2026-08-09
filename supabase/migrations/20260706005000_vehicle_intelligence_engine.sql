create table if not exists public.equipment_rules (
  id uuid primary key default gen_random_uuid(),
  rule_key text not null unique,
  cargo_category text,
  rule_description text not null,
  recommended_vehicle_type text,
  recommended_trailer_type text,
  manager_review_required boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.vehicle_recommendations (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  recommended_vehicle_type text not null,
  recommended_trailer_type text not null,
  number_of_trucks integer not null default 1,
  estimated_payload_utilization_percent numeric(7, 2) not null default 0,
  estimated_volume_utilization_percent numeric(7, 2) not null default 0,
  abnormal_load boolean not null default false,
  permit_required boolean not null default false,
  escort_recommended boolean not null default false,
  hazmat_required boolean not null default false,
  refrigeration_required boolean not null default false,
  crane_required boolean not null default false,
  forklift_required boolean not null default false,
  manager_review_required boolean not null default false,
  recommendation_notes text,
  override_vehicle_type text,
  override_trailer_type text,
  override_reason text,
  overridden_by uuid references public.internal_users(id),
  overridden_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.transport_requirement_flags (
  id uuid primary key default gen_random_uuid(),
  quote_request_id uuid not null references public.quote_requests(id) on delete cascade,
  vehicle_recommendation_id uuid references public.vehicle_recommendations(id) on delete cascade,
  flag_key text not null,
  flag_label text not null,
  severity text not null default 'info',
  flag_notes text,
  created_at timestamptz not null default now()
);

create trigger ttaq_vehicle_recommendations_touch_updated_at
before update on public.vehicle_recommendations
for each row execute function public.ttaq_touch_updated_at();

alter table public.equipment_rules enable row level security;
alter table public.vehicle_recommendations enable row level security;
alter table public.transport_requirement_flags enable row level security;

create policy "Internal users read equipment rules"
on public.equipment_rules
for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));

create policy "Owner manages equipment rules"
on public.equipment_rules
for all
using (
  public.ttaq_internal_user_role(auth.uid()) = 'owner'
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules')
)
with check (
  public.ttaq_internal_user_role(auth.uid()) = 'owner'
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules')
);

create policy "Internal users read vehicle recommendations"
on public.vehicle_recommendations
for select
using (
  exists (
    select 1
    from public.quote_requests qr
    where qr.id = vehicle_recommendations.quote_request_id
      and (
        public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
        or qr.assigned_internal_user_id = auth.uid()
        or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
      )
  )
);

create policy "Owner and manager manage vehicle recommendations"
on public.vehicle_recommendations
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read transport flags"
on public.transport_requirement_flags
for select
using (
  exists (
    select 1
    from public.quote_requests qr
    where qr.id = transport_requirement_flags.quote_request_id
      and (
        public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
        or qr.assigned_internal_user_id = auth.uid()
        or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
      )
  )
);

create policy "Owner and manager manage transport flags"
on public.transport_requirement_flags
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create index if not exists ttaq_vehicle_recommendations_quote_request_id_idx
  on public.vehicle_recommendations(quote_request_id);
create index if not exists ttaq_transport_flags_quote_request_id_idx
  on public.transport_requirement_flags(quote_request_id);
create index if not exists ttaq_equipment_rules_rule_key_idx
  on public.equipment_rules(rule_key);

insert into public.equipment_rules (
  rule_key,
  cargo_category,
  rule_description,
  recommended_vehicle_type,
  recommended_trailer_type,
  manager_review_required
)
values
  ('general_freight_light', 'general_freight', 'Light general cargo can usually move on an 8 ton or 14 ton vehicle.', '8 ton / 14 ton', 'Curtain side', false),
  ('pallets_medium', 'general_freight', 'Medium palletised freight should be reviewed for tautliner or curtain side capacity.', '14 ton', 'Tautliner / curtain side', false),
  ('machinery_flatdeck', 'machinery', 'Machinery usually requires flatdeck, crane, or lowbed review depending on dimensions and weight.', 'Rigid truck / horse', 'Flatdeck / tri-axle', true),
  ('dangerous_goods_hazmat', 'dangerous_goods', 'Dangerous goods require hazmat-capable vehicle and documentation review.', 'Hazmat-capable vehicle', 'Hazmat-compatible trailer', true),
  ('refrigerated_goods', 'refrigerated', 'Temperature-controlled freight requires refrigerated equipment.', 'Refrigerated vehicle', 'Refrigerated trailer', true),
  ('heavy_equipment_lowbed', 'machinery', 'Very heavy or oversized equipment requires lowbed review.', 'Heavy haulage truck', 'Lowbed', true),
  ('abnormal_dimensions', null, 'Abnormal dimensions may require permits and escorts.', 'Specialised vehicle', 'Abnormal load trailer', true),
  ('high_value_cargo', null, 'High-value cargo requires manager and insurance review.', 'Manager review', 'Secure transport review', true)
on conflict (rule_key) do update
set rule_description = excluded.rule_description,
    recommended_vehicle_type = excluded.recommended_vehicle_type,
    recommended_trailer_type = excluded.recommended_trailer_type,
    manager_review_required = excluded.manager_review_required,
    is_active = true;

create or replace function public.ttaq_generate_vehicle_recommendation(target_quote_request_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  total_weight numeric := 0;
  total_volume numeric := 0;
  max_length numeric := 0;
  max_width numeric := 0;
  max_height numeric := 0;
  total_value numeric := 0;
  has_dangerous boolean := false;
  has_temperature boolean := false;
  has_fragile boolean := false;
  has_machinery boolean := false;
  has_crane_answer boolean := false;
  has_forklift_text boolean := false;
  abnormal_load_value boolean := false;
  permit_required_value boolean := false;
  escort_recommended_value boolean := false;
  crane_required_value boolean := false;
  forklift_required_value boolean := false;
  manager_review_value boolean := false;
  vehicle_type text := '8 ton / 14 ton';
  trailer_type text := 'Curtain side';
  trucks integer := 1;
  payload_capacity numeric := 8000;
  volume_capacity numeric := 45;
  payload_util numeric := 0;
  volume_util numeric := 0;
  notes text;
  recommendation_id uuid;
begin
  select
    coalesce(sum(coalesce(qi.quantity, 1) * coalesce(qi.weight_kg, 0)), 0),
    coalesce(sum(coalesce(qi.quantity, 1) * coalesce(qi.length_m, 0) * coalesce(qi.width_m, 0) * coalesce(qi.height_m, 0)), 0),
    coalesce(max(coalesce(qi.length_m, 0)), 0),
    coalesce(max(coalesce(qi.width_m, 0)), 0),
    coalesce(max(coalesce(qi.height_m, 0)), 0),
    coalesce(sum(coalesce(qi.cargo_value, 0)), 0),
    coalesce(bool_or(coalesce(qi.dangerous_goods, false) or qi.cargo_category::text = 'dangerous_goods'), false),
    coalesce(bool_or(coalesce(qi.temperature_controlled, false) or qi.cargo_category::text = 'refrigerated'), false),
    coalesce(bool_or(coalesce(qi.fragile, false)), false),
    coalesce(bool_or(qi.cargo_category::text = 'machinery'), false)
  into
    total_weight,
    total_volume,
    max_length,
    max_width,
    max_height,
    total_value,
    has_dangerous,
    has_temperature,
    has_fragile,
    has_machinery
  from public.quote_items qi
  where qi.quote_request_id = target_quote_request_id;

  select coalesce(bool_or(lower(coalesce(answer_value, '')) in ('yes', 'true', 'required')), false)
    into has_crane_answer
  from public.rfq_dynamic_answers
  where quote_request_id = target_quote_request_id
    and question_key in ('crane_required', 'crane', 'lifting_required');

  select coalesce(bool_or(
      lower(coalesce(loading_method, '')) like '%forklift%'
      or lower(coalesce(offloading_method, '')) like '%forklift%'
    ), false)
    into has_forklift_text
  from public.quote_stops
  where quote_request_id = target_quote_request_id;

  abnormal_load_value := max_length > 12 or max_width > 2.5 or max_height > 4.3 or total_weight > 30000;
  permit_required_value := abnormal_load_value;
  escort_recommended_value := max_width > 3.5 or max_length > 22 or total_weight > 45000;
  crane_required_value := has_crane_answer or (has_machinery and total_weight > 8000);
  forklift_required_value := has_forklift_text or (not has_machinery and total_weight > 1000);

  if has_temperature then
    vehicle_type := 'Refrigerated vehicle';
    trailer_type := 'Refrigerated trailer';
    payload_capacity := 28000;
    volume_capacity := 85;
  elsif has_dangerous then
    vehicle_type := 'Hazmat-capable vehicle';
    trailer_type := 'Hazmat-compatible trailer';
    payload_capacity := 28000;
    volume_capacity := 85;
  elsif abnormal_load_value or (has_machinery and (total_weight > 28000 or max_length > 12 or max_width > 2.5 or max_height > 4.3)) then
    vehicle_type := 'Heavy haulage truck';
    trailer_type := 'Lowbed';
    payload_capacity := 35000;
    volume_capacity := 70;
  elsif has_machinery or total_weight > 14000 then
    vehicle_type := 'Rigid truck / horse';
    trailer_type := 'Flatdeck / tri-axle';
    payload_capacity := 28000;
    volume_capacity := 80;
  elsif total_weight > 8000 or total_volume > 45 then
    vehicle_type := '14 ton';
    trailer_type := 'Tautliner / curtain side';
    payload_capacity := 14000;
    volume_capacity := 60;
  elsif total_weight > 3500 or total_volume > 20 then
    vehicle_type := '8 ton';
    trailer_type := 'Curtain side';
    payload_capacity := 8000;
    volume_capacity := 45;
  end if;

  trucks := greatest(
    1,
    ceiling(greatest(
      case when payload_capacity > 0 then total_weight / payload_capacity else 1 end,
      case when volume_capacity > 0 then total_volume / volume_capacity else 1 end
    ))::integer
  );

  payload_util := least(100, round((total_weight / nullif(payload_capacity * trucks, 0)) * 100, 2));
  volume_util := least(100, round((total_volume / nullif(volume_capacity * trucks, 0)) * 100, 2));

  manager_review_value :=
    abnormal_load_value
    or permit_required_value
    or escort_recommended_value
    or has_dangerous
    or has_temperature
    or crane_required_value
    or total_value >= 500000
    or has_fragile;

  notes := concat_ws(
    ' ',
    'Vehicle Intelligence summary:',
    'Total weight ' || total_weight || ' kg.',
    'Total volume ' || round(total_volume, 2) || ' m3.',
    'Max item ' || max_length || 'm L x ' || max_width || 'm W x ' || max_height || 'm H.',
    case when abnormal_load_value then 'Abnormal load review required.' else null end,
    case when has_dangerous then 'Dangerous goods present.' else null end,
    case when has_temperature then 'Temperature-controlled cargo present.' else null end,
    case when crane_required_value then 'Crane requirement flagged.' else null end,
    case when total_value >= 500000 then 'High-value cargo manager review recommended.' else null end
  );

  delete from public.transport_requirement_flags where quote_request_id = target_quote_request_id;
  delete from public.vehicle_recommendations where quote_request_id = target_quote_request_id;

  insert into public.vehicle_recommendations (
    quote_request_id,
    recommended_vehicle_type,
    recommended_trailer_type,
    number_of_trucks,
    estimated_payload_utilization_percent,
    estimated_volume_utilization_percent,
    abnormal_load,
    permit_required,
    escort_recommended,
    hazmat_required,
    refrigeration_required,
    crane_required,
    forklift_required,
    manager_review_required,
    recommendation_notes
  )
  values (
    target_quote_request_id,
    vehicle_type,
    trailer_type,
    trucks,
    coalesce(payload_util, 0),
    coalesce(volume_util, 0),
    abnormal_load_value,
    permit_required_value,
    escort_recommended_value,
    has_dangerous,
    has_temperature,
    crane_required_value,
    forklift_required_value,
    manager_review_value,
    notes
  )
  returning id into recommendation_id;

  insert into public.transport_requirement_flags (quote_request_id, vehicle_recommendation_id, flag_key, flag_label, severity, flag_notes)
  select target_quote_request_id, recommendation_id, flag_key, flag_label, severity, flag_notes
  from (
    values
      ('abnormal_load', 'Abnormal load', 'warning', 'Dimensions or weight may exceed normal transport limits.', abnormal_load_value),
      ('permit_required', 'Permit required', 'warning', 'Permit review is recommended before pricing.', permit_required_value),
      ('escort_recommended', 'Escort recommended', 'warning', 'Escort vehicle may be required.', escort_recommended_value),
      ('hazmat_required', 'Hazmat required', 'critical', 'Dangerous goods handling and documentation required.', has_dangerous),
      ('refrigeration_required', 'Refrigeration required', 'warning', 'Temperature-controlled equipment required.', has_temperature),
      ('crane_required', 'Crane required', 'warning', 'Crane loading/offloading or lifting review required.', crane_required_value),
      ('forklift_required', 'Forklift required', 'info', 'Forklift loading/offloading likely required.', forklift_required_value),
      ('manager_review_required', 'Manager review required', 'critical', 'Manager review required before final quote.', manager_review_value)
  ) as flags(flag_key, flag_label, severity, flag_notes, is_active)
  where is_active;

  update public.quote_requests
     set suggestion_notes = notes
   where id = target_quote_request_id;

  return recommendation_id;
end;
$$;

create or replace function public.ttaq_generate_vehicle_recommendation_from_status_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.to_status = 'admin_review' then
    perform public.ttaq_generate_vehicle_recommendation(new.quote_request_id);
  end if;
  return new;
end;
$$;

drop trigger if exists ttaq_status_event_vehicle_recommendation on public.quote_status_events;

create trigger ttaq_status_event_vehicle_recommendation
after insert on public.quote_status_events
for each row execute function public.ttaq_generate_vehicle_recommendation_from_status_event();

