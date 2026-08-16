create or replace function public.ttaq_prevent_zero_active_owners()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  remaining_active_owners integer;
begin
  if tg_op = 'UPDATE' then
    if old.role = 'owner'
       and old.user_status = 'active'
       and (new.role <> 'owner' or new.user_status <> 'active') then
      select count(*)
        into remaining_active_owners
      from public.internal_users
      where id <> old.id
        and role = 'owner'
        and user_status = 'active';

      if remaining_active_owners < 1 then
        raise exception 'Time Trucking must have at least one active Owner.';
      end if;
    end if;

    return new;
  end if;

  if tg_op = 'DELETE' then
    if old.role = 'owner' and old.user_status = 'active' then
      select count(*)
        into remaining_active_owners
      from public.internal_users
      where id <> old.id
        and role = 'owner'
        and user_status = 'active';

      if remaining_active_owners < 1 then
        raise exception 'Time Trucking must have at least one active Owner.';
      end if;
    end if;

    return old;
  end if;

  return null;
end;
$$;

drop trigger if exists ttaq_internal_users_prevent_zero_active_owners on public.internal_users;
create trigger ttaq_internal_users_prevent_zero_active_owners
before update or delete on public.internal_users
for each row execute function public.ttaq_prevent_zero_active_owners();

do $$
declare
  henning_record public.internal_users%rowtype;
  jacques_owner_count integer;
begin
  select *
    into henning_record
  from public.internal_users
  where lower(email) = 'hluther@questlogistics.co.za'
  limit 1;

  if not found then
    raise exception 'Henning Luther internal user record was not found; no invitation or auth account was recreated.';
  end if;

  select count(*)
    into jacques_owner_count
  from public.internal_users
  where lower(email) = 'jacquesmallan@gmail.com'
    and full_name = 'Jacques Malan'
    and role = 'owner'
    and user_status = 'active';

  if jacques_owner_count < 1 then
    raise exception 'Jacques Malan must remain an active Owner before promoting Henning Luther.';
  end if;

  update public.internal_users
     set full_name = 'Henning Luther',
         role = 'owner',
         user_status = 'active',
         can_view_all_quotes = true,
         can_manage_rfqs = true,
         can_approve_quotes = true,
         can_adjust_pricing = true,
         can_manage_pricing_rules = true,
         can_manage_users = true,
         revoked_by = null,
         revoked_at = null,
         updated_at = now()
   where id = henning_record.id;

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
    null,
    'system',
    'promote_internal_user_to_owner',
    'internal_user',
    henning_record.id::text,
    jsonb_build_object(
      'email', henning_record.email,
      'full_name', henning_record.full_name,
      'role', henning_record.role,
      'user_status', henning_record.user_status,
      'can_view_all_quotes', henning_record.can_view_all_quotes,
      'can_manage_rfqs', henning_record.can_manage_rfqs,
      'can_approve_quotes', henning_record.can_approve_quotes,
      'can_adjust_pricing', henning_record.can_adjust_pricing,
      'can_manage_pricing_rules', henning_record.can_manage_pricing_rules,
      'can_manage_users', henning_record.can_manage_users
    ),
    jsonb_build_object(
      'email', 'hluther@questlogistics.co.za',
      'full_name', 'Henning Luther',
      'role', 'owner',
      'user_status', 'active',
      'can_view_all_quotes', true,
      'can_manage_rfqs', true,
      'can_approve_quotes', true,
      'can_adjust_pricing', true,
      'can_manage_pricing_rules', true,
      'can_manage_users', true
    ),
    jsonb_build_object(
      'source', '20260810014500_promote_henning_owner_access',
      'reason', 'Correct Henning Luther from viewer/read-only to Owner/full internal access without recreating auth account.',
      'jacques_malan_preserved_owner', true,
      'supports_multiple_owners', true
    )
  );
end $$;
