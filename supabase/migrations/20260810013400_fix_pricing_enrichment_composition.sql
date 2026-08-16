create or replace function public.ttaq_apply_pricing_enrichments()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  calculation_record public.pricing_calculations%rowtype;
  request_record public.quote_requests%rowtype;
  route_record public.route_estimates%rowtype;
  recommendation_record public.vehicle_recommendations%rowtype;
  overhead_record public.company_overheads%rowtype;
  margin_record public.company_margin_profiles%rowtype;
  profile_id uuid;
  pricing_date date;
  toll_result jsonb := '{}'::jsonb;
  risk_result jsonb := '{}'::jsonb;
  toll_source_value text;
  risk_status_value text;
  old_toll_amount numeric := 0;
  final_toll_amount numeric := 0;
  toll_delta_amount numeric := 0;
  old_route_risk_amount numeric := 0;
  final_route_risk_amount numeric := 0;
  route_risk_delta_amount numeric := 0;
  combined_component_delta numeric := 0;
  original_base_before_seasonal numeric := 0;
  route_risk_base_amount numeric := 0;
  final_base_before_seasonal numeric := 0;
  seasonal_multiplier_value numeric := 1;
  final_seasonal_amount numeric := 0;
  subtotal_before_admin_overhead numeric := 0;
  company_overhead_amount numeric := 0;
  vehicle_overhead_amount numeric := 0;
  final_subtotal numeric := 0;
  margin_percent_value numeric := 0;
  minimum_profit_value numeric := 0;
  final_profit_amount numeric := 0;
  vat_percent_value numeric := 0;
  final_vat_amount numeric := 0;
  final_grand_total numeric := 0;
  minimum_selling_price_value numeric := 0;
  review_required_value boolean := false;
  dynamic_inputs_value jsonb := '{}'::jsonb;
  dynamic_outputs_value jsonb := '{}'::jsonb;
  pricing_source_snapshot_value jsonb := '{}'::jsonb;
  automation_status_value jsonb := '{}'::jsonb;
begin
  if new.rule_version not like 'pricing-v3%' then
    return new;
  end if;

  select *
    into calculation_record
  from public.pricing_calculations
  where id = new.id
  for update;

  if calculation_record.id is null then
    return new;
  end if;

  profile_id := coalesce(calculation_record.pricing_profile_id, public.ttaq_active_pricing_profile());
  dynamic_inputs_value := coalesce(calculation_record.dynamic_inputs, '{}'::jsonb);
  dynamic_outputs_value := coalesce(calculation_record.dynamic_outputs, '{}'::jsonb);
  pricing_source_snapshot_value := coalesce(calculation_record.pricing_source_snapshot, '{}'::jsonb);
  automation_status_value := coalesce(calculation_record.automation_status, '{}'::jsonb);
  review_required_value := coalesce(calculation_record.manager_review_required, false);

  select * into request_record
  from public.quote_requests
  where id = calculation_record.quote_request_id;

  select * into route_record
  from public.route_estimates
  where quote_request_id = calculation_record.quote_request_id
  order by created_at desc
  limit 1;

  select * into recommendation_record
  from public.vehicle_recommendations
  where id = calculation_record.vehicle_recommendation_id;

  select * into overhead_record
  from public.company_overheads
  where pricing_profile_id = profile_id
  order by created_at desc
  limit 1;

  select * into margin_record
  from public.company_margin_profiles
  where pricing_profile_id = profile_id
    and is_active
    and (margin_key = calculation_record.margin_profile_key or is_default)
  order by case when margin_key = calculation_record.margin_profile_key then 0 when is_default then 1 else 2 end,
           created_at desc
  limit 1;

  pricing_date := coalesce(request_record.collection_date, current_date);
  old_toll_amount := coalesce(calculation_record.toll_amount, 0);
  final_toll_amount := old_toll_amount;
  old_route_risk_amount := coalesce(calculation_record.route_risk_amount, 0);
  final_route_risk_amount := old_route_risk_amount;

  toll_result := public.ttaq_calculate_official_route_tolls(
    calculation_record.quote_request_id,
    route_record.id,
    recommendation_record.final_equipment_profile_id,
    pricing_date
  );
  toll_source_value := toll_result->>'source';

  if toll_source_value in ('automatic_official_tariff', 'toll_free_route', 'management_override') then
    final_toll_amount := coalesce((toll_result->>'amount')::numeric, 0);
    automation_status_value := automation_status_value || jsonb_build_object(
      'toll_requires_review', coalesce((toll_result->>'requires_review')::boolean, false),
      'toll_status', toll_result->>'status',
      'toll_review_warning', toll_result->>'review_warning'
    );
    review_required_value := review_required_value or coalesce((toll_result->>'requires_review')::boolean, false);
  elsif coalesce((toll_result->>'requires_review')::boolean, false) then
    automation_status_value := automation_status_value || jsonb_build_object(
      'toll_requires_review', true,
      'toll_status', toll_result->>'status',
      'toll_review_warning', toll_result->>'review_warning'
    );
    review_required_value := true;
  end if;

  toll_delta_amount := final_toll_amount - old_toll_amount;

  original_base_before_seasonal := coalesce(
    nullif(dynamic_outputs_value->>'base_cost_before_seasonal', '')::numeric,
    coalesce(calculation_record.subtotal, 0)
      - coalesce(nullif(dynamic_outputs_value->>'company_overhead_amount', '')::numeric, 0)
      - coalesce(calculation_record.seasonal_amount, 0)
  );
  route_risk_base_amount := greatest(original_base_before_seasonal - old_route_risk_amount + toll_delta_amount, 0);

  risk_result := public.ttaq_evaluate_route_risk_policy(
    calculation_record.quote_request_id,
    route_record.id,
    route_risk_base_amount,
    pricing_date
  );
  risk_status_value := risk_result->>'status';

  if risk_status_value in ('automatic_configured_policy', 'no_risk_match', 'no_configured_policy_match', 'manual_override') then
    final_route_risk_amount := coalesce((risk_result->>'amount')::numeric, 0);
    automation_status_value := automation_status_value || jsonb_build_object(
      'route_risk_requires_review', coalesce((risk_result->>'requires_review')::boolean, false),
      'route_risk_status', risk_status_value,
      'route_risk_reason', risk_result->>'reason'
    );
    review_required_value := review_required_value or coalesce((risk_result->>'requires_review')::boolean, false);
  else
    automation_status_value := automation_status_value || jsonb_build_object(
      'route_risk_requires_review', true,
      'route_risk_status', risk_status_value,
      'route_risk_reason', risk_result->>'reason'
    );
    review_required_value := true;
  end if;

  route_risk_delta_amount := final_route_risk_amount - old_route_risk_amount;
  combined_component_delta := toll_delta_amount + route_risk_delta_amount;
  final_base_before_seasonal := greatest(route_risk_base_amount + final_route_risk_amount, 0);
  seasonal_multiplier_value := coalesce(calculation_record.seasonal_multiplier, 1);
  final_seasonal_amount := round(final_base_before_seasonal * (seasonal_multiplier_value - 1), 2);
  subtotal_before_admin_overhead := final_base_before_seasonal + final_seasonal_amount;
  company_overhead_amount := round(subtotal_before_admin_overhead * (coalesce(overhead_record.admin_overhead_percent, 0) / 100), 2);
  vehicle_overhead_amount := coalesce(nullif(dynamic_outputs_value->>'vehicle_overhead_amount', '')::numeric, 0);
  final_subtotal := round(subtotal_before_admin_overhead + company_overhead_amount, 2);
  margin_percent_value := coalesce(calculation_record.margin_percent, margin_record.margin_percent, overhead_record.profit_margin_percent, 0);
  minimum_profit_value := coalesce(margin_record.minimum_profit, overhead_record.minimum_profit, 0);
  final_profit_amount := greatest(round(final_subtotal * (margin_percent_value / 100), 2), minimum_profit_value, 0);
  vat_percent_value := coalesce(overhead_record.vat_percent, 0);
  final_vat_amount := round((final_subtotal + final_profit_amount) * (vat_percent_value / 100), 2);
  final_grand_total := final_subtotal + final_profit_amount + final_vat_amount;
  minimum_selling_price_value := public.ttaq_pricing_setting(profile_id, 'minimum_selling_price');

  if minimum_selling_price_value > 0 and final_grand_total < minimum_selling_price_value then
    final_grand_total := minimum_selling_price_value;
    review_required_value := true;
    automation_status_value := automation_status_value || jsonb_build_object('minimum_selling_price_applied', true);
  else
    automation_status_value := automation_status_value || jsonb_build_object('minimum_selling_price_applied', false);
  end if;

  pricing_source_snapshot_value := pricing_source_snapshot_value
    || jsonb_build_object(
      'tolls', toll_result,
      'route_risk', risk_result,
      'commercial', coalesce(pricing_source_snapshot_value->'commercial', '{}'::jsonb) || jsonb_build_object(
        'margin_percent', margin_percent_value,
        'minimum_profit', minimum_profit_value,
        'vat_percent', vat_percent_value,
        'admin_overhead_percent', coalesce(overhead_record.admin_overhead_percent, 0),
        'minimum_selling_price', minimum_selling_price_value,
        'pricing_order', jsonb_build_array(
          'operating_and_requirement_costs',
          'official_tolls',
          'route_risk',
          'seasonal_multiplier',
          'company_admin_overhead',
          'profit_minimum_profit',
          'vat',
          'minimum_selling_price_floor'
        )
      ),
      'finalisation', jsonb_build_object(
        'base_cost_before_seasonal', final_base_before_seasonal,
        'toll_amount', final_toll_amount,
        'toll_delta', toll_delta_amount,
        'route_risk_amount', final_route_risk_amount,
        'route_risk_delta', route_risk_delta_amount,
        'combined_component_delta', combined_component_delta,
        'seasonal_amount', final_seasonal_amount,
        'company_overhead_amount', company_overhead_amount,
        'subtotal', final_subtotal,
        'profit_amount', final_profit_amount,
        'vat_amount', final_vat_amount,
        'recommended_selling_price', final_grand_total
      )
    );

  dynamic_inputs_value := dynamic_inputs_value || jsonb_build_object('tolls', toll_result, 'route_risk', risk_result);
  dynamic_outputs_value := dynamic_outputs_value || jsonb_build_object(
    'base_cost_before_seasonal', final_base_before_seasonal,
    'route_risk_base_amount', route_risk_base_amount,
    'toll_amount', final_toll_amount,
    'route_risk_amount', final_route_risk_amount,
    'toll_pricing_delta', toll_delta_amount,
    'route_risk_pricing_delta', route_risk_delta_amount,
    'combined_pricing_enrichment_delta', combined_component_delta,
    'seasonal_amount', final_seasonal_amount,
    'company_overhead_amount', company_overhead_amount,
    'calculated_cost_before_profit_vat', final_subtotal,
    'profit_amount', final_profit_amount,
    'expected_margin_percent', round((final_profit_amount / nullif(final_subtotal, 0)) * 100, 4),
    'vat_amount', final_vat_amount,
    'grand_total', final_grand_total
  );

  update public.pricing_calculations
     set toll_amount = final_toll_amount,
         route_risk_amount = final_route_risk_amount,
         seasonal_amount = final_seasonal_amount,
         subtotal = final_subtotal,
         profit_amount = final_profit_amount,
         vat_amount = final_vat_amount,
         grand_total = final_grand_total,
         recommended_selling_price = final_grand_total,
         margin_percent = margin_percent_value,
         dynamic_inputs = dynamic_inputs_value,
         dynamic_outputs = dynamic_outputs_value,
         pricing_source_snapshot = pricing_source_snapshot_value,
         automation_status = automation_status_value,
         manager_review_required = review_required_value
   where id = calculation_record.id;

  update public.pricing_breakdowns
     set quantity = greatest(coalesce((toll_result->>'matched_plaza_count')::numeric, 0), case when final_toll_amount > 0 then 1 else 0 end),
         unit_rate = final_toll_amount,
         amount = final_toll_amount,
         explanation = case
           when toll_source_value = 'toll_free_route' then 'Official plaza matching completed and no toll plazas apply to this route.'
           when toll_source_value = 'management_override' then 'Management override applied after official toll calculation snapshot.'
           when toll_source_value = 'automatic_official_tariff' then 'Official VAT-inclusive toll tariff matched to route geometry and confirmed equipment toll class.'
           else coalesce(toll_result->>'review_warning', 'Toll pricing requires review; existing fallback amount retained until management approves.')
         end
   where pricing_calculation_id = calculation_record.id
     and line_key = 'tolls';

  update public.pricing_breakdowns
     set quantity = route_risk_base_amount,
         unit_rate = coalesce((risk_result->>'surcharge_percent')::numeric, 0),
         amount = final_route_risk_amount,
         explanation = case
           when risk_status_value in ('no_risk_match', 'no_configured_policy_match') then risk_result->>'reason'
           when risk_status_value = 'manual_override' then 'Management override applied to Time Trucking route-risk policy result.'
           when risk_status_value = 'automatic_configured_policy' then 'Time Trucking configured route-risk policy selected the controlling rule and surcharge.'
           else coalesce(risk_result->>'reason', 'Route risk requires management review; existing fallback amount retained until management approves.')
         end
   where pricing_calculation_id = calculation_record.id
     and line_key = 'route_risk';

  update public.pricing_breakdowns
     set quantity = final_base_before_seasonal,
         unit_rate = seasonal_multiplier_value,
         amount = final_seasonal_amount
   where pricing_calculation_id = calculation_record.id
     and line_key = 'seasonal_multiplier';

  update public.pricing_breakdowns
     set quantity = subtotal_before_admin_overhead,
         unit_rate = coalesce(overhead_record.admin_overhead_percent, 0),
         amount = company_overhead_amount + vehicle_overhead_amount
   where pricing_calculation_id = calculation_record.id
     and line_key = 'overhead';

  update public.pricing_breakdowns
     set quantity = final_subtotal,
         unit_rate = margin_percent_value,
         amount = final_profit_amount
   where pricing_calculation_id = calculation_record.id
     and line_key = 'profit';

  update public.pricing_breakdowns
     set quantity = final_subtotal + final_profit_amount,
         unit_rate = vat_percent_value,
         amount = final_vat_amount
   where pricing_calculation_id = calculation_record.id
     and line_key = 'vat';

  return new;
end;
$$;

drop trigger if exists ttaq_apply_official_toll_pricing_enrichment on public.pricing_calculations;
drop trigger if exists ttaq_apply_route_risk_policy_enrichment on public.pricing_calculations;
drop trigger if exists ttaq_apply_pricing_enrichments on public.pricing_calculations;

create trigger ttaq_apply_pricing_enrichments
after insert on public.pricing_calculations
for each row execute function public.ttaq_apply_pricing_enrichments();

comment on function public.ttaq_apply_pricing_enrichments() is
  'Single deterministic pricing finalisation trigger for official toll and route-risk enrichment. It locks the inserted calculation row, composes explicit toll/risk deltas, and recomputes seasonal amount, admin overhead, profit/minimum profit, VAT, final totals, snapshots, and breakdowns atomically.';
