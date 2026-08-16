create or replace function public.ttaq_save_commercial_pricing_settings(settings_payload jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_id uuid;
  night_out_rate_value numeric;
begin
  if not public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules') then
    raise exception 'Not allowed to manage commercial pricing settings';
  end if;

  profile_id := public.ttaq_active_pricing_profile();
  if profile_id is null then
    raise exception 'No active pricing profile configured';
  end if;

  insert into public.pricing_settings (pricing_profile_id, setting_key, setting_value, setting_unit, description)
  values
    (profile_id, 'commercial_rate_basis_rule', coalesce(nullif(settings_payload->>'commercial_rate_basis_rule', '')::numeric, 0), 'enum', '0 pending confirmation, 1 per-km, 2 per-day'),
    (profile_id, 'commercial_chargeable_day_count_default', coalesce(nullif(settings_payload->>'commercial_chargeable_day_count_default', '')::numeric, 1), 'days', 'Default chargeable day count for commercial day-rate scenario'),
    (profile_id, 'night_out_rate', coalesce(nullif(settings_payload->>'night_out_rate', '')::numeric, 1750), 'ZAR/night', 'Time Trucking confirmed driver night-out allowance'),
    (profile_id, 'night_out_count_default', coalesce(nullif(settings_payload->>'night_out_count_default', '')::numeric, 0), 'count', 'Explicit night-out count default; automatic trigger pending Henning confirmation'),
    (profile_id, 'diesel_selling_adjustment_enabled', coalesce(nullif(settings_payload->>'diesel_selling_adjustment_enabled', '')::numeric, 0), 'boolean', 'Customer selling-price diesel adjustment remains inactive pending approved formula'),
    (profile_id, 'commercial_additional_margin_percent', coalesce(nullif(settings_payload->>'commercial_additional_margin_percent', '')::numeric, 0), 'percent', 'Additional commercial margin on top of Henning rates; inactive unless approved'),
    (profile_id, 'commercial_10_percent_protection_enabled', coalesce(nullif(settings_payload->>'commercial_10_percent_protection_enabled', '')::numeric, 0), 'boolean', '10 percent protection pending exact Time Trucking definition')
  on conflict (pricing_profile_id, setting_key) do update
  set setting_value = excluded.setting_value,
      setting_unit = excluded.setting_unit,
      description = excluded.description,
      updated_at = now();

  night_out_rate_value := coalesce(nullif(settings_payload->>'night_out_rate', '')::numeric, 1750);

  update public.driver_costs
     set driver_overnight_allowance = night_out_rate_value,
         updated_at = now()
   where pricing_profile_id = profile_id;

  update public.pricing_profiles
     set rule_version = 'pricing-v3-commercial-rate-card',
         updated_at = now()
   where id = profile_id;
end;
$$;

revoke all on function public.ttaq_save_commercial_pricing_settings(jsonb) from public;
grant execute on function public.ttaq_save_commercial_pricing_settings(jsonb) to authenticated;

comment on function public.ttaq_save_commercial_pricing_settings(jsonb) is
  'Persists Pricing Settings UI fields for the commercial rate-card architecture without changing pricing formulas.';
