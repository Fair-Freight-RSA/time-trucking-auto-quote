create or replace function public.ttaq_diesel_scheduler_status()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  cron_record record;
  provider_record record;
begin
  select jobname, schedule, active, command
    into cron_record
  from cron.job
  where jobname = 'ttaq-daily-official-diesel-refresh'
  limit 1;

  select provider_key, provider_status, scheduler_status, last_check_at, next_expected_check_at,
         last_success_at, last_failure_at, last_error, last_publication_effective_date,
         last_publication_title
    into provider_record
  from public.pricing_external_providers
  where provider_key = 'za_dmpr_official_diesel';

  return jsonb_build_object(
    'cron_job', case when cron_record.jobname is null then null else jsonb_build_object(
      'jobname', cron_record.jobname,
      'schedule', cron_record.schedule,
      'active', cron_record.active,
      'command_references_scheduler_function', position('ttaq_trigger_official_diesel_refresh' in cron_record.command) > 0,
      'command_contains_secret_literal', position('x-diesel-refresh-secret' in cron_record.command) > 0
    ) end,
    'provider', to_jsonb(provider_record)
  );
end;
$$;

revoke all on function public.ttaq_diesel_scheduler_status() from public;
revoke all on function public.ttaq_diesel_scheduler_status() from anon;
revoke all on function public.ttaq_diesel_scheduler_status() from authenticated;
grant execute on function public.ttaq_diesel_scheduler_status() to service_role;
