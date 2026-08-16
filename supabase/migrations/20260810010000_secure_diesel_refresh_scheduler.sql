create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema extensions;
create extension if not exists supabase_vault with schema vault;

alter table public.pricing_external_providers
  add column if not exists last_check_at timestamptz,
  add column if not exists next_expected_check_at timestamptz,
  add column if not exists last_publication_effective_date date,
  add column if not exists last_publication_title text,
  add column if not exists scheduler_status text not null default 'not_configured';

create table if not exists public.pricing_provider_refresh_runs (
  id uuid primary key default gen_random_uuid(),
  provider_key text not null,
  trigger_source text not null,
  request_id bigint,
  requested_at timestamptz not null default now(),
  requested_by uuid references public.internal_users(id),
  status text not null default 'queued',
  notes text,
  created_at timestamptz not null default now()
);

alter table public.pricing_provider_refresh_runs enable row level security;

drop policy if exists "Internal users read provider refresh runs" on public.pricing_provider_refresh_runs;
create policy "Internal users read provider refresh runs"
on public.pricing_provider_refresh_runs
for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));

drop policy if exists "Owner manages provider refresh runs" on public.pricing_provider_refresh_runs;
create policy "Owner manages provider refresh runs"
on public.pricing_provider_refresh_runs
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules'));

create or replace function public.ttaq_vault_upsert_secret(
  secret_name text,
  secret_value text,
  secret_description text
)
returns void
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  existing_id uuid;
begin
  if nullif(secret_name, '') is null or nullif(secret_value, '') is null then
    raise exception 'Secret name and value are required.';
  end if;

  select id into existing_id
  from vault.decrypted_secrets
  where name = secret_name
  order by created_at desc
  limit 1;

  if existing_id is null then
    perform vault.create_secret(secret_value, secret_name, secret_description);
  else
    perform vault.update_secret(existing_id, secret_value, secret_name, secret_description);
  end if;
end;
$$;

revoke all on function public.ttaq_vault_upsert_secret(text, text, text) from public;
revoke all on function public.ttaq_vault_upsert_secret(text, text, text) from anon;
revoke all on function public.ttaq_vault_upsert_secret(text, text, text) from authenticated;
grant execute on function public.ttaq_vault_upsert_secret(text, text, text) to service_role;

create or replace function public.ttaq_trigger_official_diesel_refresh(trigger_source_value text default 'scheduled')
returns bigint
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  refresh_secret text;
  publishable_key text;
  request_id bigint;
begin
  select decrypted_secret into refresh_secret
  from vault.decrypted_secrets
  where name = 'ttaq_diesel_refresh_secret'
  order by created_at desc
  limit 1;

  select decrypted_secret into publishable_key
  from vault.decrypted_secrets
  where name = 'ttaq_supabase_publishable_key'
  order by created_at desc
  limit 1;

  if nullif(refresh_secret, '') is null or nullif(publishable_key, '') is null then
    update public.pricing_external_providers
       set provider_status = 'failed',
           scheduler_status = 'needs_attention',
           last_failure_at = now(),
           last_error = 'Diesel refresh scheduler is missing Vault secrets.'
     where provider_key = 'za_dmpr_official_diesel';

    insert into public.pricing_provider_refresh_runs (provider_key, trigger_source, status, notes)
    values ('za_dmpr_official_diesel', coalesce(nullif(trigger_source_value, ''), 'scheduled'), 'failed', 'Missing Vault secrets');

    raise exception 'Diesel refresh scheduler is missing Vault secrets.';
  end if;

  select net.http_post(
    url := 'https://uxbbmrmkiopacaxdwvrp.functions.supabase.co/production-integrations',
    body := jsonb_build_object('action', 'refresh_official_diesel'),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', publishable_key,
      'Authorization', 'Bearer ' || publishable_key,
      'x-diesel-refresh-secret', refresh_secret
    ),
    timeout_milliseconds := 15000
  ) into request_id;

  update public.pricing_external_providers
     set last_check_at = now(),
         next_expected_check_at = now() + interval '1 day',
         scheduler_status = 'queued',
         last_error = null
   where provider_key = 'za_dmpr_official_diesel';

  insert into public.pricing_provider_refresh_runs (provider_key, trigger_source, request_id, status)
  values ('za_dmpr_official_diesel', coalesce(nullif(trigger_source_value, ''), 'scheduled'), request_id, 'queued');

  return request_id;
end;
$$;

revoke all on function public.ttaq_trigger_official_diesel_refresh(text) from public;
revoke all on function public.ttaq_trigger_official_diesel_refresh(text) from anon;
revoke all on function public.ttaq_trigger_official_diesel_refresh(text) from authenticated;
grant execute on function public.ttaq_trigger_official_diesel_refresh(text) to service_role;

create or replace function public.ttaq_install_diesel_refresh_schedule(
  refresh_secret_value text,
  publishable_key_value text
)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
begin
  if nullif(refresh_secret_value, '') is null or nullif(publishable_key_value, '') is null then
    raise exception 'Refresh secret and publishable key are required.';
  end if;

  perform public.ttaq_vault_upsert_secret(
    'ttaq_diesel_refresh_secret',
    refresh_secret_value,
    'Time Trucking official diesel refresh scheduler secret'
  );

  perform public.ttaq_vault_upsert_secret(
    'ttaq_supabase_publishable_key',
    publishable_key_value,
    'Time Trucking Supabase publishable key for scheduled Edge Function invocation'
  );

  perform cron.unschedule('ttaq-daily-official-diesel-refresh')
  where exists (select 1 from cron.job where jobname = 'ttaq-daily-official-diesel-refresh');

  perform cron.schedule(
    'ttaq-daily-official-diesel-refresh',
    '17 4 * * *',
    $job$select public.ttaq_trigger_official_diesel_refresh('scheduled');$job$
  );

  update public.pricing_external_providers
     set scheduler_status = 'configured',
         next_expected_check_at = coalesce(next_expected_check_at, now() + interval '1 day'),
         refresh_cadence = 'Daily at 04:17 UTC; records a new official value only when a newer effective publication/value is detected.'
   where provider_key = 'za_dmpr_official_diesel';
end;
$$;

revoke all on function public.ttaq_install_diesel_refresh_schedule(text, text) from public;
revoke all on function public.ttaq_install_diesel_refresh_schedule(text, text) from anon;
revoke all on function public.ttaq_install_diesel_refresh_schedule(text, text) from authenticated;
grant execute on function public.ttaq_install_diesel_refresh_schedule(text, text) to service_role;
