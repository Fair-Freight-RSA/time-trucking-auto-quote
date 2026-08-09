do $$
begin
  if not exists (select 1 from pg_type where typname = 'ttaq_internal_role' and typnamespace = 'public'::regnamespace) then
    create type public.ttaq_internal_role as enum ('owner', 'manager', 'staff', 'viewer');
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'ttaq_user_status' and typnamespace = 'public'::regnamespace) then
    create type public.ttaq_user_status as enum ('active', 'revoked');
  end if;
end $$;

create table public.internal_users (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  full_name text,
  role public.ttaq_internal_role not null default 'viewer',
  user_status public.ttaq_user_status not null default 'active',
  can_view_all_quotes boolean not null default false,
  can_manage_rfqs boolean not null default false,
  can_approve_quotes boolean not null default false,
  can_adjust_pricing boolean not null default false,
  can_manage_pricing_rules boolean not null default false,
  can_manage_users boolean not null default false,
  invited_by uuid references public.internal_users(id),
  invited_at timestamptz not null default now(),
  revoked_by uuid references public.internal_users(id),
  revoked_at timestamptz,
  last_login_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint internal_users_revoked_timestamp_check
    check ((user_status = 'revoked' and revoked_at is not null) or user_status = 'active'),
  constraint internal_users_owner_permissions_check
    check (
      role <> 'owner'
      or (
        can_view_all_quotes
        and can_manage_rfqs
        and can_approve_quotes
        and can_adjust_pricing
        and can_manage_pricing_rules
        and can_manage_users
      )
    )
);

comment on table public.internal_users is
  'Time Trucking internal users only. Public clients must not have records here and must not log into internal pages.';
comment on column public.internal_users.role is
  'owner has full access; manager can manage RFQs and approve quotes; staff has limited assigned/internal access; viewer is read-only.';
comment on column public.internal_users.user_status is
  'Use revoked instead of deleting users so quote approvals and audit trails remain intact.';

alter table public.quote_requests
  add column assigned_internal_user_id uuid references public.internal_users(id),
  add column created_by_internal_user_id uuid references public.internal_users(id);

alter table public.quote_versions
  add column approved_by_internal_user_id uuid references public.internal_users(id);

alter table public.pricing_rules
  add column created_by_internal_user_id uuid references public.internal_users(id);

create trigger ttaq_internal_users_touch_updated_at
before update on public.internal_users
for each row execute function public.ttaq_touch_updated_at();

create or replace function public.ttaq_internal_user_role(user_id uuid)
returns public.ttaq_internal_role
language sql
security definer
set search_path = public
stable
as $$
  select iu.role
  from public.internal_users iu
  where iu.id = user_id
    and iu.user_status = 'active'
  limit 1;
$$;

create or replace function public.ttaq_has_internal_permission(user_id uuid, permission_name text)
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
      and (
        iu.role = 'owner'
        or (permission_name = 'manage_users' and iu.can_manage_users)
        or (permission_name = 'manage_rfqs' and iu.can_manage_rfqs)
        or (permission_name = 'approve_quotes' and iu.can_approve_quotes)
        or (permission_name = 'adjust_pricing' and iu.can_adjust_pricing)
        or (permission_name = 'manage_pricing_rules' and iu.can_manage_pricing_rules)
        or (permission_name = 'view_all_quotes' and iu.can_view_all_quotes)
      )
  );
$$;

create or replace function public.ttaq_can_manage_users(user_id uuid)
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
      and (iu.role in ('owner', 'manager') or iu.can_manage_users)
  );
$$;

create or replace function public.ttaq_can_approve_quotes(user_id uuid)
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
      and (iu.role in ('owner', 'manager') or iu.can_approve_quotes)
  );
$$;

create or replace function public.ttaq_revoke_internal_user(target_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_role public.ttaq_internal_role;
  target_role public.ttaq_internal_role;
begin
  actor_role := public.ttaq_internal_user_role(auth.uid());
  target_role := public.ttaq_internal_user_role(target_user_id);

  if actor_role not in ('owner', 'manager') then
    raise exception 'Only owner or manager can revoke internal users';
  end if;

  if target_role = 'owner' and actor_role <> 'owner' then
    raise exception 'Managers cannot revoke an owner';
  end if;

  if target_user_id = auth.uid() and target_role = 'owner' then
    raise exception 'Owner cannot revoke their own account';
  end if;

  update public.internal_users
     set user_status = 'revoked',
         revoked_by = auth.uid(),
         revoked_at = now()
   where id = target_user_id;
end;
$$;

alter table public.internal_users enable row level security;

drop policy if exists "Admin users can manage admin_users" on public.admin_users;
drop policy if exists "Admins manage clients" on public.clients;
drop policy if exists "Admins manage client_contacts" on public.client_contacts;
drop policy if exists "Admins manage quote_requests" on public.quote_requests;
drop policy if exists "Admins manage quote_items" on public.quote_items;
drop policy if exists "Admins manage quote_status_events" on public.quote_status_events;
drop policy if exists "Admins manage vehicle_types" on public.vehicle_types;
drop policy if exists "Admins manage trailer_types" on public.trailer_types;
drop policy if exists "Admins manage pricing_rules" on public.pricing_rules;
drop policy if exists "Admins manage quote_versions" on public.quote_versions;
drop policy if exists "Admins manage notifications" on public.notifications;
drop policy if exists "Admins manage email_logs" on public.email_logs;

create policy "Internal users can read their own profile"
on public.internal_users
for select
using (auth.uid() = id or public.ttaq_can_manage_users(auth.uid()));

create policy "Owner and manager can invite internal users"
on public.internal_users
for insert
with check (
  public.ttaq_can_manage_users(auth.uid())
  and (role <> 'owner' or public.ttaq_internal_user_role(auth.uid()) = 'owner')
);

create policy "Owner and manager can update internal users"
on public.internal_users
for update
using (
  public.ttaq_can_manage_users(auth.uid())
  and (role <> 'owner' or public.ttaq_internal_user_role(auth.uid()) = 'owner')
)
with check (
  public.ttaq_can_manage_users(auth.uid())
  and (role <> 'owner' or public.ttaq_internal_user_role(auth.uid()) = 'owner')
);

create policy "Owner manages legacy admin_users"
on public.admin_users
for all
using (public.ttaq_internal_user_role(auth.uid()) = 'owner')
with check (public.ttaq_internal_user_role(auth.uid()) = 'owner');

create policy "Internal users read clients"
on public.clients
for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));

create policy "Owner and manager manage clients"
on public.clients
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read client contacts"
on public.client_contacts
for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));

create policy "Owner and manager manage client contacts"
on public.client_contacts
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read allowed quote requests"
on public.quote_requests
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or assigned_internal_user_id = auth.uid()
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
);

create policy "Owner and manager manage RFQs"
on public.quote_requests
for update
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Owner and manager create RFQs"
on public.quote_requests
for insert
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read allowed quote items"
on public.quote_items
for select
using (
  exists (
    select 1
    from public.quote_requests qr
    where qr.id = quote_items.quote_request_id
      and (
        public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
        or qr.assigned_internal_user_id = auth.uid()
        or public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs')
      )
  )
);

create policy "Owner and manager manage quote items"
on public.quote_items
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read quote status events"
on public.quote_status_events
for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));

create policy "Owner and manager create quote status events"
on public.quote_status_events
for insert
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Internal users read vehicle types"
on public.vehicle_types
for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));

create policy "Owner manages vehicle types"
on public.vehicle_types
for all
using (
  public.ttaq_internal_user_role(auth.uid()) = 'owner'
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules')
)
with check (
  public.ttaq_internal_user_role(auth.uid()) = 'owner'
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules')
);

create policy "Internal users read trailer types"
on public.trailer_types
for select
using (public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes'));

create policy "Owner manages trailer types"
on public.trailer_types
for all
using (
  public.ttaq_internal_user_role(auth.uid()) = 'owner'
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules')
)
with check (
  public.ttaq_internal_user_role(auth.uid()) = 'owner'
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules')
);

create policy "Internal users read quote versions"
on public.quote_versions
for select
using (
  public.ttaq_has_internal_permission(auth.uid(), 'view_all_quotes')
  or exists (
    select 1
    from public.quote_requests qr
    where qr.id = quote_versions.quote_request_id
      and qr.assigned_internal_user_id = auth.uid()
  )
);

create policy "Owner and manager approve quote versions"
on public.quote_versions
for update
using (public.ttaq_can_approve_quotes(auth.uid()))
with check (public.ttaq_can_approve_quotes(auth.uid()));

create policy "Owner and manager create quote versions"
on public.quote_versions
for insert
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Owner reads notifications"
on public.notifications
for select
using (public.ttaq_can_manage_users(auth.uid()));

create policy "Owner and manager manage notifications"
on public.notifications
for all
using (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'))
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Owner reads email logs"
on public.email_logs
for select
using (public.ttaq_can_manage_users(auth.uid()));

create policy "Owner and manager create email logs"
on public.email_logs
for insert
with check (public.ttaq_has_internal_permission(auth.uid(), 'manage_rfqs'));

create policy "Owner adjusts pricing rules"
on public.pricing_rules
for update
using (
  public.ttaq_internal_user_role(auth.uid()) = 'owner'
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules')
)
with check (
  public.ttaq_internal_user_role(auth.uid()) = 'owner'
  or public.ttaq_has_internal_permission(auth.uid(), 'manage_pricing_rules')
);

create index ttaq_internal_users_role_idx on public.internal_users(role);
create index ttaq_internal_users_status_idx on public.internal_users(user_status);
create index ttaq_quote_requests_assigned_internal_user_idx on public.quote_requests(assigned_internal_user_id);
