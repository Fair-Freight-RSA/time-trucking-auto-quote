do $$
declare
  function_sql text;
begin
  select pg_get_functiondef('public.ttaq_submit_public_rfq(text,text,jsonb,boolean)'::regprocedure)
    into function_sql;

  function_sql := replace(function_sql, E'\n  answer_record jsonb;', '');
  function_sql := replace(function_sql, 'answer_record->>', 'dynamic_answer_record->>');
  function_sql := replace(function_sql, ') answer_record', ') dynamic_answer_record');

  execute function_sql;
end;
$$;
