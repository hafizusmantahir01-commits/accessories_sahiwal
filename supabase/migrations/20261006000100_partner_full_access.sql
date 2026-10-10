-- =====================================================================
-- Partner "full access": a partner the owner trusts can do everything the
-- owner does (products, prices, stock, purchases, costs, profit, history)
-- WITHOUT the private password — except managing users and the private
-- password itself, which stay with the real owner. Every change is still
-- written to the audit log with the partner's name and role.
-- =====================================================================

alter table public.profiles add column if not exists full_access boolean not null default false;

-- The real owner only (old meaning of is_owner).
create or replace function internal.is_real_owner()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
     where p.id = auth.uid()
       and p.role = 'owner'
       and p.is_active
       and internal.current_auth_time() >= p.sessions_valid_after
  )
$$;

create or replace function internal.is_full_partner()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
     where p.id = auth.uid()
       and p.role = 'partner'
       and p.is_active
       and p.full_access
       and internal.current_auth_time() >= p.sessions_valid_after
  )
$$;

-- "Acts as owner" for business data: owner, or a full-access partner.
create or replace function internal.is_owner()
returns boolean language sql stable security definer set search_path = '' as $$
  select internal.is_real_owner() or internal.is_full_partner()
$$;

-- Owner needs the private password; a full-access partner is always "unlocked".
create or replace function internal.is_owner_unlocked()
returns boolean language sql stable security definer set search_path = '' as $$
  select internal.is_full_partner() or (internal.is_real_owner() and exists (
    select 1 from internal.private_unlocks u
     where u.session_id = internal.current_session_id()
       and u.user_id = auth.uid()
       and u.expires_at > now()
  ))
$$;

create or replace function internal.require_real_owner_unlocked()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not internal.is_real_owner() then
    raise exception 'Only the owner can do this' using errcode = '42501';
  end if;
  if not internal.is_owner_unlocked() then
    raise exception 'PRIVATE_LOCKED: Unlock the Owner Private Area first' using errcode = '42501';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Things that stay with the REAL owner
-- ---------------------------------------------------------------------

-- Profiles: partner reads only their own row and can never edit permissions.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or (select internal.is_real_owner()));
drop policy if exists profiles_owner_update on public.profiles;
create policy profiles_owner_update on public.profiles for update to authenticated
  using ((select internal.is_real_owner() and internal.is_owner_unlocked()))
  with check ((select internal.is_real_owner() and internal.is_owner_unlocked()));

create or replace function internal.guard_profile_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') and not internal.is_real_owner() then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  if current_user in ('authenticated', 'anon') and new.id = auth.uid()
     and (new.role <> old.role or new.is_active <> old.is_active) then
    raise exception 'Owner cannot change own role or active state' using errcode = '42501';
  end if;
  if new.role = 'owner' and old.role <> 'owner' and current_user in ('authenticated', 'anon') then
    raise exception 'Ownership cannot be granted from the app' using errcode = '42501';
  end if;
  return new;
end $$;

-- private_status reports is_owner only for the real owner, so the
-- admin-users Edge Function keeps refusing partners.
create or replace function public.private_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_exp timestamptz; v_has_secret boolean;
begin
  if not internal.is_real_owner() then
    return jsonb_build_object('is_owner', false, 'unlocked', internal.is_full_partner(),
                              'has_secret', true, 'full_access', internal.is_full_partner());
  end if;
  select expires_at into v_exp from internal.private_unlocks
   where session_id = internal.current_session_id() and user_id = auth.uid() and expires_at > now();
  v_has_secret := exists (select 1 from internal.private_secret);
  return jsonb_build_object('is_owner', true, 'unlocked', v_exp is not null,
                            'expires_at', v_exp, 'has_secret', v_has_secret);
end $$;

create or replace function public.set_private_secret(p_current text, p_new text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_hash text;
begin
  if not internal.is_real_owner() then
    raise exception 'Only the owner can do this' using errcode = '42501';
  end if;
  if p_new is null or char_length(p_new) < 8 then
    raise exception 'Private password must be at least 8 characters' using errcode = '22023';
  end if;
  select secret_hash into v_hash from internal.private_secret where id = 1;
  if v_hash is not null and (p_current is null or extensions.crypt(p_current, v_hash) <> v_hash) then
    raise exception 'Current private password is incorrect' using errcode = '28P01';
  end if;
  insert into internal.private_secret (id, secret_hash)
  values (1, extensions.crypt(p_new, extensions.gen_salt('bf', 10)))
  on conflict (id) do update set secret_hash = excluded.secret_hash, updated_at = now();
  delete from internal.private_unlocks where session_id is not null;
  perform internal.audit('private_secret_changed', 'private_area', null);
end $$;

drop function if exists public.owner_list_users();
create function public.owner_list_users()
returns table (id uuid, email text, full_name text, role public.user_role, is_active boolean,
               can_create_sale boolean, can_override_price boolean, full_access boolean,
               last_sign_in_at timestamptz, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_real_owner_unlocked();
  return query
    select p.id, u.email::text, p.full_name, p.role, p.is_active, p.can_create_sale,
           p.can_override_price, p.full_access, u.last_sign_in_at, p.created_at
      from public.profiles p join auth.users u on u.id = p.id
     order by p.role, p.full_name;
end $$;

create or replace function public.owner_set_user_access(
  p_user_id uuid, p_is_active boolean, p_can_create_sale boolean, p_can_override_price boolean,
  p_full_name text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_before jsonb; v_after jsonb;
begin
  perform internal.require_real_owner_unlocked();
  if p_user_id = auth.uid() then
    raise exception 'Owner access cannot be changed here' using errcode = '42501';
  end if;
  select to_jsonb(p) into v_before from public.profiles p where p.id = p_user_id and p.role = 'partner';
  if v_before is null then
    raise exception 'Partner not found' using errcode = 'P0002';
  end if;
  update public.profiles
     set is_active = p_is_active,
         can_create_sale = p_can_create_sale,
         can_override_price = p_can_override_price,
         full_name = coalesce(nullif(btrim(p_full_name), ''), full_name),
         sessions_valid_after = case when not p_is_active then now() else sessions_valid_after end
   where id = p_user_id
  returning to_jsonb(profiles.*) into v_after;
  perform internal.audit('user_access_changed', 'profile', p_user_id::text, null, v_before, v_after);
end $$;

-- Turn full access on/off for a partner (owner only).
create or replace function public.owner_set_full_access(p_user_id uuid, p_enabled boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare v_before jsonb; v_after jsonb;
begin
  perform internal.require_real_owner_unlocked();
  select to_jsonb(p) into v_before from public.profiles p where p.id = p_user_id and p.role = 'partner';
  if v_before is null then
    raise exception 'Partner not found' using errcode = 'P0002';
  end if;
  update public.profiles
     set full_access = coalesce(p_enabled, false),
         can_create_sale = can_create_sale or coalesce(p_enabled, false),
         can_override_price = can_override_price or coalesce(p_enabled, false)
   where id = p_user_id
  returning to_jsonb(profiles.*) into v_after;
  perform internal.audit(case when p_enabled then 'partner_full_access_on' else 'partner_full_access_off' end,
                         'profile', p_user_id::text, null, v_before, v_after);
end $$;

create or replace function public.owner_revoke_sessions(p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform internal.require_real_owner_unlocked();
  update public.profiles set sessions_valid_after = now() where id = p_user_id;
  if p_user_id = auth.uid() then
    delete from internal.private_unlocks where user_id = p_user_id;
  end if;
  perform internal.audit('sessions_revoked', 'profile', p_user_id::text);
end $$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
revoke execute on function internal.is_real_owner(), internal.is_full_partner(),
  internal.require_real_owner_unlocked() from public, anon;
grant execute on function internal.is_real_owner(), internal.is_full_partner() to authenticated;
revoke execute on function public.owner_list_users(), public.owner_set_full_access(uuid, boolean) from public, anon;
grant execute on function public.owner_list_users(), public.owner_set_full_access(uuid, boolean) to authenticated;
