alter table public.standard_equipment_profiles
  add column if not exists axle_count integer,
  add column if not exists toll_class_criteria jsonb not null default '{}'::jsonb;

with default_axles(equipment_code, axle_count_value, source_label) as (
  values
    ('bakkie-panel-1t', 2, 'Henning confirmed: 1 Ton = 2 axles'),
    ('rigid-8t-tautliner', 2, 'Henning confirmed: 8 Ton = 2 axles'),
    ('tri-axle-tautliner', 9, 'Henning confirmed: Semi = 9 axles'),
    ('tri-axle-flatdeck', 9, 'Henning confirmed: Semi = 9 axles'),
    ('superlink-tautliner', 10, 'Henning confirmed: S/L = 10 axles'),
    ('superlink-flatdeck', 10, 'Henning confirmed: S/L = 10 axles')
)
update public.standard_equipment_profiles equipment
   set axle_count = coalesce(equipment.axle_count, default_axles.axle_count_value),
       toll_class_criteria = coalesce(equipment.toll_class_criteria, '{}'::jsonb)
         || jsonb_build_object(
           'default_axle_count', coalesce(equipment.axle_count, default_axles.axle_count_value),
           'default_axle_source', default_axles.source_label,
           'toll_class_note', 'Axle count is stored for audit/classification evidence only. Existing toll_class remains the pricing selector until Time Trucking confirms operator-specific classification.'
         )
  from default_axles
 where equipment.equipment_code = default_axles.equipment_code;

comment on column public.standard_equipment_profiles.axle_count is
  'Default vehicle axle count used as toll-classification evidence. Henning supplied defaults; toll class is still selected separately from operator classification rules.';
