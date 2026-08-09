create extension if not exists pgcrypto;

create or replace function public.ttaq_get_current_internal_user()
returns table (
  id uuid,
  email text,
  full_name text,
  role public.ttaq_internal_role,
  user_status public.ttaq_user_status,
  can_view_all_quotes boolean,
  can_manage_rfqs boolean,
  can_approve_quotes boolean,
  can_adjust_pricing boolean,
  can_manage_pricing_rules boolean,
  can_manage_users boolean,
  last_login_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  update public.internal_users iu
     set last_login_at = now()
   where iu.id = auth.uid()
     and iu.user_status = 'active';

  return query
  select
    iu.id,
    iu.email,
    iu.full_name,
    iu.role,
    iu.user_status,
    iu.can_view_all_quotes,
    iu.can_manage_rfqs,
    iu.can_approve_quotes,
    iu.can_adjust_pricing,
    iu.can_manage_pricing_rules,
    iu.can_manage_users,
    iu.last_login_at
  from public.internal_users iu
  where iu.id = auth.uid()
  limit 1;
end;
$$;
