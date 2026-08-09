create extension if not exists pgcrypto;

create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid,
  actor_role text,
  action text not null,
  entity_type text not null,
  entity_id text,
  old_values jsonb not null default '{}'::jsonb,
  new_values jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.system_settings (
  id uuid primary key default gen_random_uuid(),
  setting_key text not null unique,
  setting_category text not null default 'general',
  display_name text not null,
  setting_value jsonb not null default '{}'::jsonb,
  is_restricted boolean not null default false,
  updated_by uuid references public.internal_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.company_branding_settings (
  setting_key text primary key default 'default',
  company_name text not null default 'Time Trucking',
  trading_name text,
  website_url text default 'https://timetrucking.co.za',
  logo_url text,
  primary_color text default '#17202c',
  accent_color text default '#f4b942',
  contact_email text,
  contact_phone text,
  address text,
  quote_footer text,
  updated_by uuid references public.internal_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint company_branding_settings_singleton check (setting_key = 'default')
);

create table if not exists public.email_template_placeholders (
  template_key text primary key,
  template_name text not null,
  subject_placeholder text not null,
  body_placeholder text not null,
  available_variables jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  updated_by uuid references public.internal_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.numbering_sequence_settings (
  sequence_key text primary key,
  display_name text not null,
  prefix text not null,
  next_number integer not null default 1,
  padding integer not null default 5,
  suffix text,
  last_generated_at timestamptz,
  updated_by uuid references public.internal_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint numbering_sequence_settings_next_number_check check (next_number > 0),
  constraint numbering_sequence_settings_padding_check check (padding between 1 and 12)
);

drop trigger if exists ttaq_system_settings_touch_updated_at on public.system_settings;
create trigger ttaq_system_settings_touch_updated_at
before update on public.system_settings
for each row execute function public.ttaq_touch_updated_at();

drop trigger if exists ttaq_company_branding_settings_touch_updated_at on public.company_branding_settings;
create trigger ttaq_company_branding_settings_touch_updated_at
before update on public.company_branding_settings
for each row execute function public.ttaq_touch_updated_at();

drop trigger if exists ttaq_email_template_placeholders_touch_updated_at on public.email_template_placeholders;
create trigger ttaq_email_template_placeholders_touch_updated_at
before update on public.email_template_placeholders
for each row execute function public.ttaq_touch_updated_at();

drop trigger if exists ttaq_numbering_sequence_settings_touch_updated_at on public.numbering_sequence_settings;
create trigger ttaq_numbering_sequence_settings_touch_updated_at
before update on public.numbering_sequence_settings
for each row execute function public.ttaq_touch_updated_at();

insert into public.company_branding_settings (
  setting_key,
  company_name,
  trading_name,
  website_url,
  primary_color,
  accent_color,
  contact_email,
  contact_phone,
  quote_footer
)
values (
  'default',
  'Time Trucking',
  'Time Trucking',
  'https://timetrucking.co.za',
  '#17202c',
  '#f4b942',
  'quotes@timetrucking.co.za',
  '',
  'Thank you for choosing Time Trucking. This quote is subject to availability, final route confirmation, and Time Trucking terms and conditions.'
)
on conflict (setting_key) do nothing;

insert into public.system_settings (setting_key, setting_category, display_name, setting_value, is_restricted)
values
  ('security_policy', 'security', 'Security policy', '{"public_pages":["client-rfq.html","quote-response.html","quote-view.html","customer-portal.html"],"internal_auth_required":true,"settings_owner_only":true}'::jsonb, true),
  ('quote_validity_defaults', 'quotes', 'Quote validity defaults', '{"validity_days":7,"expiry_warning_days":1}'::jsonb, false),
  ('document_defaults', 'documents', 'Document defaults', '{"pdf_bucket":"quote-documents","customer_safe_only":true}'::jsonb, false),
  ('notification_defaults', 'notifications', 'Notification defaults', '{"email_mode":"placeholder","store_email_logs":true}'::jsonb, false)
on conflict (setting_key) do nothing;

insert into public.email_template_placeholders (
  template_key,
  template_name,
  subject_placeholder,
  body_placeholder,
  available_variables
)
values
  ('rfq_link', 'RFQ link email', 'Time Trucking RFQ link: {{public_reference}}', 'Hello {{contact_person}}, please complete your transport RFQ using {{rfq_link}}.', '["company_name","contact_person","public_reference","rfq_link"]'::jsonb),
  ('quote_sent', 'Customer quote email', 'Time Trucking quote {{quote_number}}', 'Hello {{contact_person}}, your Time Trucking quote is ready: {{quote_link}}.', '["company_name","contact_person","quote_number","quote_link","valid_until"]'::jsonb),
  ('quote_accepted_internal', 'Quote accepted internal alert', 'Quote accepted: {{quote_number}}', 'Quote {{quote_number}} has been accepted by {{company_name}} and is ready for job conversion.', '["company_name","quote_number","public_reference"]'::jsonb),
  ('invoice_ready', 'Invoice ready email', 'Time Trucking invoice {{invoice_number}}', 'Hello {{contact_person}}, invoice {{invoice_number}} is available in your customer portal.', '["company_name","contact_person","invoice_number","portal_link"]'::jsonb)
on conflict (template_key) do nothing;

insert into public.numbering_sequence_settings (sequence_key, display_name, prefix, next_number, padding, suffix)
values
  ('rfq', 'RFQ numbers', 'RFQ-', 1, 5, null),
  ('quote', 'Quote numbers', 'TTQ-', 1, 5, null),
  ('job', 'Transport job numbers', 'JOB-', 1, 5, null),
  ('invoice', 'Invoice numbers', 'INV-', 1, 5, null)
on conflict (sequence_key) do nothing;

alter table public.audit_logs enable row level security;
alter table public.system_settings enable row level security;
alter table public.company_branding_settings enable row level security;
alter table public.email_template_placeholders enable row level security;
alter table public.numbering_sequence_settings enable row level security;

drop policy if exists "Owner reads audit logs" on public.audit_logs;
create policy "Owner reads audit logs"
on public.audit_logs
for select
using (public.ttaq_internal_user_role(auth.uid()) = 'owner');

drop policy if exists "Internal users read system settings" on public.system_settings;
create policy "Internal users read system settings"
on public.system_settings
for select
using (
  public.ttaq_internal_user_role(auth.uid()) = 'owner'
  or (
    is_restricted = false
    and (
      public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
      or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
    )
  )
);

drop policy if exists "Owner manages system settings" on public.system_settings;
create policy "Owner manages system settings"
on public.system_settings
for all
using (public.ttaq_internal_user_role(auth.uid()) = 'owner')
with check (public.ttaq_internal_user_role(auth.uid()) = 'owner');

drop policy if exists "Internal users read company branding settings" on public.company_branding_settings;
create policy "Internal users read company branding settings"
on public.company_branding_settings
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

drop policy if exists "Owner manages company branding settings" on public.company_branding_settings;
create policy "Owner manages company branding settings"
on public.company_branding_settings
for all
using (public.ttaq_internal_user_role(auth.uid()) = 'owner')
with check (public.ttaq_internal_user_role(auth.uid()) = 'owner');

drop policy if exists "Internal users read email template placeholders" on public.email_template_placeholders;
create policy "Internal users read email template placeholders"
on public.email_template_placeholders
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

drop policy if exists "Owner manages email template placeholders" on public.email_template_placeholders;
create policy "Owner manages email template placeholders"
on public.email_template_placeholders
for all
using (public.ttaq_internal_user_role(auth.uid()) = 'owner')
with check (public.ttaq_internal_user_role(auth.uid()) = 'owner');

drop policy if exists "Internal users read numbering settings" on public.numbering_sequence_settings;
create policy "Internal users read numbering settings"
on public.numbering_sequence_settings
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

drop policy if exists "Owner manages numbering settings" on public.numbering_sequence_settings;
create policy "Owner manages numbering settings"
on public.numbering_sequence_settings
for all
using (public.ttaq_internal_user_role(auth.uid()) = 'owner')
with check (public.ttaq_internal_user_role(auth.uid()) = 'owner');

create or replace function public.ttaq_can_update_internal_settings(user_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.internal_users iu
    where iu.id = user_id
      and iu.user_status = 'active'
      and iu.role = 'owner'
  )
  or exists (
    select 1
    from public.admin_users au
    where au.id = user_id
      and au.is_active = true
      and au.role in ('owner', 'admin')
  );
$$;

create or replace function public.ttaq_get_internal_settings()
returns table (settings_payload jsonb)
language sql
security definer
set search_path = public
stable
as $$
  select jsonb_build_object(
    'can_update',
      public.ttaq_can_update_internal_settings(auth.uid()),
    'company_branding',
      coalesce((select to_jsonb(cbs) - 'updated_by' from public.company_branding_settings cbs where cbs.setting_key = 'default'), '{}'::jsonb),
    'system_settings',
      coalesce((
        select jsonb_agg(to_jsonb(ss) - 'updated_by' order by ss.setting_category, ss.setting_key)
        from public.system_settings ss
        where public.ttaq_can_update_internal_settings(auth.uid()) or ss.is_restricted = false
      ), '[]'::jsonb),
    'email_templates',
      coalesce((
        select jsonb_agg(to_jsonb(etp) - 'updated_by' order by etp.template_key)
        from public.email_template_placeholders etp
      ), '[]'::jsonb),
    'numbering_sequences',
      coalesce((
        select jsonb_agg(to_jsonb(nss) - 'updated_by' order by nss.sequence_key)
        from public.numbering_sequence_settings nss
      ), '[]'::jsonb),
    'recent_audit_logs',
      case
        when public.ttaq_internal_user_role(auth.uid()) = 'owner' then
          coalesce((
            select jsonb_agg(to_jsonb(al) order by al.created_at desc)
            from (
              select *
              from public.audit_logs
              order by created_at desc
              limit 25
            ) al
          ), '[]'::jsonb)
        else '[]'::jsonb
      end
  ) as settings_payload
  where (
    public.ttaq_can_update_internal_settings(auth.uid())
    or public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
    or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
  );
$$;

create or replace function public.ttaq_update_internal_settings(settings_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_role text;
  company_payload jsonb;
  system_record jsonb;
  template_record jsonb;
  sequence_record jsonb;
  old_snapshot jsonb;
  new_snapshot jsonb;
begin
  if not public.ttaq_can_update_internal_settings(auth.uid()) then
    raise exception 'Only approved owner/admin Time Trucking users can update internal settings.';
  end if;

  actor_role := coalesce(public.ttaq_internal_user_role(auth.uid())::text, 'admin');
  select gis.settings_payload
    into old_snapshot
  from public.ttaq_get_internal_settings() as gis
  limit 1;

  company_payload := coalesce(settings_payload->'company_branding', '{}'::jsonb);
  if company_payload <> '{}'::jsonb then
    insert into public.company_branding_settings (
      setting_key,
      company_name,
      trading_name,
      website_url,
      logo_url,
      primary_color,
      accent_color,
      contact_email,
      contact_phone,
      address,
      quote_footer,
      updated_by
    )
    values (
      'default',
      coalesce(nullif(company_payload->>'company_name', ''), 'Time Trucking'),
      nullif(company_payload->>'trading_name', ''),
      nullif(company_payload->>'website_url', ''),
      nullif(company_payload->>'logo_url', ''),
      coalesce(nullif(company_payload->>'primary_color', ''), '#17202c'),
      coalesce(nullif(company_payload->>'accent_color', ''), '#f4b942'),
      nullif(company_payload->>'contact_email', ''),
      nullif(company_payload->>'contact_phone', ''),
      nullif(company_payload->>'address', ''),
      nullif(company_payload->>'quote_footer', ''),
      auth.uid()
    )
    on conflict (setting_key) do update
    set company_name = excluded.company_name,
        trading_name = excluded.trading_name,
        website_url = excluded.website_url,
        logo_url = excluded.logo_url,
        primary_color = excluded.primary_color,
        accent_color = excluded.accent_color,
        contact_email = excluded.contact_email,
        contact_phone = excluded.contact_phone,
        address = excluded.address,
        quote_footer = excluded.quote_footer,
        updated_by = excluded.updated_by;
  end if;

  for system_record in
    select value from jsonb_array_elements(coalesce(settings_payload->'system_settings', '[]'::jsonb))
  loop
    insert into public.system_settings (
      setting_key,
      setting_category,
      display_name,
      setting_value,
      is_restricted,
      updated_by
    )
    values (
      system_record->>'setting_key',
      coalesce(nullif(system_record->>'setting_category', ''), 'general'),
      coalesce(nullif(system_record->>'display_name', ''), system_record->>'setting_key'),
      coalesce(system_record->'setting_value', '{}'::jsonb),
      coalesce((system_record->>'is_restricted')::boolean, false),
      auth.uid()
    )
    on conflict (setting_key) do update
    set setting_category = excluded.setting_category,
        display_name = excluded.display_name,
        setting_value = excluded.setting_value,
        is_restricted = excluded.is_restricted,
        updated_by = excluded.updated_by;
  end loop;

  for template_record in
    select value from jsonb_array_elements(coalesce(settings_payload->'email_templates', '[]'::jsonb))
  loop
    insert into public.email_template_placeholders (
      template_key,
      template_name,
      subject_placeholder,
      body_placeholder,
      available_variables,
      is_active,
      updated_by
    )
    values (
      template_record->>'template_key',
      coalesce(nullif(template_record->>'template_name', ''), template_record->>'template_key'),
      coalesce(template_record->>'subject_placeholder', ''),
      coalesce(template_record->>'body_placeholder', ''),
      coalesce(template_record->'available_variables', '[]'::jsonb),
      coalesce((template_record->>'is_active')::boolean, true),
      auth.uid()
    )
    on conflict (template_key) do update
    set template_name = excluded.template_name,
        subject_placeholder = excluded.subject_placeholder,
        body_placeholder = excluded.body_placeholder,
        available_variables = excluded.available_variables,
        is_active = excluded.is_active,
        updated_by = excluded.updated_by;
  end loop;

  for sequence_record in
    select value from jsonb_array_elements(coalesce(settings_payload->'numbering_sequences', '[]'::jsonb))
  loop
    insert into public.numbering_sequence_settings (
      sequence_key,
      display_name,
      prefix,
      next_number,
      padding,
      suffix,
      updated_by
    )
    values (
      sequence_record->>'sequence_key',
      coalesce(nullif(sequence_record->>'display_name', ''), sequence_record->>'sequence_key'),
      coalesce(sequence_record->>'prefix', ''),
      greatest(coalesce((sequence_record->>'next_number')::integer, 1), 1),
      least(greatest(coalesce((sequence_record->>'padding')::integer, 5), 1), 12),
      nullif(sequence_record->>'suffix', ''),
      auth.uid()
    )
    on conflict (sequence_key) do update
    set display_name = excluded.display_name,
        prefix = excluded.prefix,
        next_number = excluded.next_number,
        padding = excluded.padding,
        suffix = excluded.suffix,
        updated_by = excluded.updated_by;
  end loop;

  select gis.settings_payload
    into new_snapshot
  from public.ttaq_get_internal_settings() as gis
  limit 1;

  insert into public.audit_logs (
    actor_user_id,
    actor_role,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values,
    metadata
  )
  values (
    auth.uid(),
    actor_role,
    'update_internal_settings',
    'internal_settings',
    'module_14',
    coalesce(old_snapshot, '{}'::jsonb),
    coalesce(new_snapshot, '{}'::jsonb),
    jsonb_build_object('source', 'admin-settings.html')
  );

  return coalesce(new_snapshot, '{}'::jsonb);
end;
$$;
