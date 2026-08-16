create or replace function public.ttaq_sync_diesel_provider_scheduler_health()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.provider_name <> 'za_dmpr_official_diesel' then
    return new;
  end if;

  if new.provider_status in ('success', 'verified', 'live') then
    update public.pricing_external_providers
       set provider_status = 'configured',
           scheduler_status = 'configured',
           last_success_at = coalesce(new.refreshed_at, new.created_at, now()),
           last_error = null,
           last_publication_effective_date = new.effective_from,
           last_publication_title = coalesce(new.source_document_title, new.provider_response->>'source_title'),
           next_expected_check_at = coalesce(next_expected_check_at, now() + interval '1 day')
     where provider_key = 'za_dmpr_official_diesel';
  else
    update public.pricing_external_providers
       set provider_status = 'failed',
           scheduler_status = 'needs_attention',
           last_failure_at = coalesce(new.refreshed_at, new.created_at, now()),
           last_error = coalesce(new.error_message, new.provider_response->>'error', 'Official diesel provider failed.')
     where provider_key = 'za_dmpr_official_diesel';
  end if;

  return new;
end;
$$;

drop trigger if exists ttaq_sync_diesel_provider_scheduler_health_trigger on public.diesel_price_integrations;
create trigger ttaq_sync_diesel_provider_scheduler_health_trigger
after insert or update on public.diesel_price_integrations
for each row execute function public.ttaq_sync_diesel_provider_scheduler_health();

update public.pricing_external_providers p
   set scheduler_status = 'configured',
       last_publication_effective_date = d.effective_from,
       last_publication_title = coalesce(d.source_document_title, d.provider_response->>'source_title'),
       last_error = null
from (
  select distinct on (provider_name)
    provider_name,
    effective_from,
    source_document_title,
    provider_response
  from public.diesel_price_integrations
  where provider_name = 'za_dmpr_official_diesel'
    and provider_status in ('success', 'verified', 'live')
    and coalesce(effective_diesel_price_per_litre, provider_price_per_litre, 0) between 5 and 35
  order by provider_name, effective_from desc, created_at desc
) d
where p.provider_key = d.provider_name;
