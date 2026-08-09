do $$
declare
  function_sql text;
begin
  select pg_get_functiondef('public.ttaq_generate_quote_document(uuid)'::regprocedure)
    into function_sql;

  function_sql := replace(
    function_sql,
    E'from public.vehicle_recommendations\n  where quote_request_id = request_record.id',
    E'from public.vehicle_recommendations\n  where vehicle_recommendations.quote_request_id = request_record.id'
  );
  function_sql := replace(
    function_sql,
    E'from public.route_estimates\n  where quote_request_id = request_record.id',
    E'from public.route_estimates\n  where route_estimates.quote_request_id = request_record.id'
  );
  function_sql := replace(
    function_sql,
    E'from public.pricing_calculations\n  where quote_request_id = request_record.id',
    E'from public.pricing_calculations\n  where pricing_calculations.quote_request_id = request_record.id'
  );

  execute function_sql;
end;
$$;
