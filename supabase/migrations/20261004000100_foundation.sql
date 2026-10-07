-- =====================================================================
-- Accessories Sahiwal — Stage 1: Foundation
-- Identity, roles, permissions, Owner Private Area unlock, settings, audit.
--
-- Schemas:
--   public   : shared data exposed through the API (protected by RLS)
--   private  : owner-only financial data. Exposed to the API ONLY so the
--              owner can read it; every policy requires owner + unlocked
--              private area. Add "private" to Exposed schemas in Supabase.
--   internal : secrets, unlock sessions and helper functions. NEVER exposed.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
create schema if not exists internal;

revoke all on schema internal from public, anon, authenticated;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;
alter default privileges in schema internal revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from public, anon;

-- ---------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------
create type public.user_role as enum ('owner', 'partner');
create type public.payment_method as enum ('cash', 'bank_transfer', 'jazzcash', 'easypaisa');

-- ---------------------------------------------------------------------
-- Profiles (one per auth user). No self-registration: a profile is
-- created inactive and only the owner can activate it.
-- ---------------------------------------------------------------------
create table public.profiles (
  id                    uuid primary key references auth.users(id) on delete cascade,
  full_name             text not null default '' check (char_length(full_name) <= 120),
  role                  public.user_role not null default 'partner',
  is_active             boolean not null default false,
  can_create_sale       boolean not null default false,
  can_override_price    boolean not null default false,
  sessions_valid_after  timestamptz not null default '1970-01-01'::timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- Only one owner may ever exist.
create unique index profiles_single_owner on public.profiles ((true)) where role = 'owner';

-- ---------------------------------------------------------------------
-- Business settings (single row) — branding is data, not code.
-- ---------------------------------------------------------------------
create table public.business_settings (
  id                  smallint primary key default 1 check (id = 1),
  business_name       text not null default 'Accessories Sahiwal',
  logo_text           text not null default 'AS' check (char_length(logo_text) between 1 and 4),
  logo_path           text,               -- storage path in "branding" bucket, null = monogram
  address             text not null default '',
  phone               text not null default '',
  receipt_footer      text not null default '',
  currency_code       text not null default 'PKR',
  timezone            text not null default 'Asia/Karachi',
  low_stock_default   integer not null default 5 check (low_stock_default >= 0),
  trading_started_at  timestamptz,        -- once set, opening stock is closed
  updated_at          timestamptz not null default now()
);
insert into public.business_settings (id) values (1);

-- ---------------------------------------------------------------------
-- Owner Private Area ("locked folder")
-- ---------------------------------------------------------------------
create table internal.private_secret (
  id             smallint primary key default 1 check (id = 1),
  secret_hash    text not null,
  updated_at     timestamptz not null default now()
);

create table internal.private_unlocks (
  session_id   uuid primary key,          -- Supabase JWT session_id claim
  user_id      uuid not null references auth.users(id) on delete cascade,
  unlocked_at  timestamptz not null default now(),
  expires_at   timestamptz not null
);

create table internal.unlock_attempts (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  failed_count   integer not null default 0,
  locked_until   timestamptz,
  last_failed_at timestamptz
);

-- ---------------------------------------------------------------------
-- Audit log (owner-readable)
-- ---------------------------------------------------------------------
create table private.audit_logs (
  id          bigint generated always as identity primary key,
  actor_id    uuid references auth.users(id) on delete set null,
  action      text not null,
  entity      text not null,
  entity_id   text,
  reason      text,
  before_data jsonb,
  after_data  jsonb,
  created_at  timestamptz not null default now()
);
create index audit_logs_created_idx on private.audit_logs (created_at desc);
create index audit_logs_entity_idx on private.audit_logs (entity, entity_id);

-- =====================================================================
-- Helper functions (internal, security definer, fixed search_path)
-- =====================================================================

create or replace function internal.jwt_claims()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;

create or replace function internal.current_session_id()
returns uuid language sql stable set search_path = '' as $$
  select nullif(internal.jwt_claims() ->> 'session_id', '')::uuid
$$;

-- Time of the original sign-in for this session. Supabase keeps the "amr"
-- timestamps across token refreshes, so revoking sessions forces re-login.
create or replace function internal.current_auth_time()
returns timestamptz language sql stable set search_path = '' as $$
  select to_timestamp(coalesce(
    (select max((a ->> 'timestamp')::bigint)
       from jsonb_array_elements(
              case when jsonb_typeof(internal.jwt_claims() -> 'amr') = 'array'
                   then internal.jwt_claims() -> 'amr' else '[]'::jsonb end) a),
    (internal.jwt_claims() ->> 'iat')::bigint,
    0))
$$;

create or replace function internal.is_active_user()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
     where p.id = auth.uid()
       and p.is_active
       and internal.current_auth_time() >= p.sessions_valid_after
  )
$$;

create or replace function internal.is_owner()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
     where p.id = auth.uid()
       and p.role = 'owner'
       and p.is_active
       and internal.current_auth_time() >= p.sessions_valid_after
  )
$$;

create or replace function internal.has_permission(p_permission text)
returns boolean language sql stable security definer set search_path = '' as $$
  select internal.is_owner() or exists (
    select 1 from public.profiles p
     where p.id = auth.uid()
       and p.is_active
       and internal.current_auth_time() >= p.sessions_valid_after
       and case p_permission
             when 'create_sale'    then p.can_create_sale
             when 'override_price' then p.can_override_price
             else false
           end
  )
$$;

create or replace function internal.is_owner_unlocked()
returns boolean language sql stable security definer set search_path = '' as $$
  select internal.is_owner() and exists (
    select 1 from internal.private_unlocks u
     where u.session_id = internal.current_session_id()
       and u.user_id = auth.uid()
       and u.expires_at > now()
  )
$$;

create or replace function internal.require_active()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not internal.is_active_user() then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
end $$;

create or replace function internal.require_owner()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not internal.is_owner() then
    raise exception 'Owner access required' using errcode = '42501';
  end if;
end $$;

create or replace function internal.require_owner_unlocked()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not internal.is_owner() then
    raise exception 'Owner access required' using errcode = '42501';
  end if;
  if not internal.is_owner_unlocked() then
    raise exception 'PRIVATE_LOCKED: Unlock the Owner Private Area first' using errcode = '42501';
  end if;
end $$;

create or replace function internal.audit(
  p_action text, p_entity text, p_entity_id text,
  p_reason text default null, p_before jsonb default null, p_after jsonb default null)
returns void language sql security definer set search_path = '' as $$
  insert into private.audit_logs (actor_id, action, entity, entity_id, reason, before_data, after_data)
  values (auth.uid(), p_action, p_entity, p_entity_id, p_reason, p_before, p_after)
$$;

create or replace function internal.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger profiles_touch before update on public.profiles
  for each row execute function internal.touch_updated_at();
create trigger settings_touch before update on public.business_settings
  for each row execute function internal.touch_updated_at();

-- Every new auth user gets an INACTIVE partner profile.
create or replace function internal.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', ''))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function internal.handle_new_auth_user();

-- Users may not change their own role / permission columns through the API.
-- Runs as the CALLING role (not security definer) so current_user is meaningful.
create or replace function internal.guard_profile_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') and not internal.is_owner() then
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

create trigger profiles_guard before update on public.profiles
  for each row execute function internal.guard_profile_update();

-- ---------------------------------------------------------------------
-- First-owner setup. Run ONCE from the Supabase SQL editor (as postgres)
-- after creating the owner's login in Authentication → Users:
--   select internal.bootstrap_owner('owner@example.com', 'Owner Name');
-- ---------------------------------------------------------------------
create or replace function internal.bootstrap_owner(p_email text, p_full_name text default 'Owner')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if exists (select 1 from public.profiles where role = 'owner') then
    raise exception 'An owner already exists';
  end if;
  select id into v_id from auth.users where lower(email) = lower(btrim(p_email));
  if v_id is null then
    raise exception 'No auth user with email %', p_email;
  end if;
  insert into public.profiles (id, full_name, role, is_active, can_create_sale, can_override_price)
  values (v_id, p_full_name, 'owner', true, true, true)
  on conflict (id) do update
     set role = 'owner', is_active = true, full_name = excluded.full_name,
         can_create_sale = true, can_override_price = true;
  return v_id;
end $$;
revoke all on function internal.bootstrap_owner(text, text) from public, anon, authenticated;

-- =====================================================================
-- RLS
-- =====================================================================
alter table public.profiles enable row level security;
alter table public.business_settings enable row level security;
alter table private.audit_logs enable row level security;
alter table internal.private_secret enable row level security;
alter table internal.private_unlocks enable row level security;
alter table internal.unlock_attempts enable row level security;

create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or (select internal.is_owner()));
create policy profiles_owner_update on public.profiles for update to authenticated
  using ((select internal.is_owner_unlocked())) with check ((select internal.is_owner_unlocked()));

create policy settings_select on public.business_settings for select to authenticated
  using ((select internal.is_active_user()));
create policy settings_owner_update on public.business_settings for update to authenticated
  using ((select internal.is_owner())) with check ((select internal.is_owner()));

create policy audit_select on private.audit_logs for select to authenticated
  using ((select internal.is_owner_unlocked()));

revoke all on public.profiles, public.business_settings from anon;
revoke insert, delete, truncate on public.profiles, public.business_settings from authenticated;
grant select, update on public.profiles, public.business_settings to authenticated;
-- Restrict which columns can be updated from the API.
revoke update on public.profiles from authenticated;
grant update (full_name, can_create_sale, can_override_price) on public.profiles to authenticated;
revoke update on public.business_settings from authenticated;
grant update (business_name, logo_text, logo_path, address, phone, receipt_footer, low_stock_default)
  on public.business_settings to authenticated;
grant select on private.audit_logs to authenticated;

-- =====================================================================
-- RPC: Owner Private Area
-- =====================================================================

create or replace function public.private_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_exp timestamptz; v_has_secret boolean;
begin
  if not internal.is_owner() then
    return jsonb_build_object('is_owner', false, 'unlocked', false, 'has_secret', false);
  end if;
  select expires_at into v_exp from internal.private_unlocks
   where session_id = internal.current_session_id() and user_id = auth.uid() and expires_at > now();
  v_has_secret := exists (select 1 from internal.private_secret);
  return jsonb_build_object('is_owner', true, 'unlocked', v_exp is not null,
                            'expires_at', v_exp, 'has_secret', v_has_secret);
end $$;

-- Set the private password. First time: only owner. Later: requires current password.
create or replace function public.set_private_secret(p_current text, p_new text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_hash text;
begin
  perform internal.require_owner();
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
  -- WHERE clause required: Supabase enforces pg-safeupdate on API requests.
  delete from internal.private_unlocks where session_id is not null;   -- revoke all existing unlocks
  perform internal.audit('private_secret_changed', 'private_area', null);
end $$;

create or replace function public.unlock_private(p_secret text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_hash text; v_sid uuid := internal.current_session_id();
  v_att internal.unlock_attempts; v_exp timestamptz;
begin
  perform internal.require_owner();
  if v_sid is null then
    raise exception 'Session not recognised; sign in again' using errcode = '42501';
  end if;
  select * into v_att from internal.unlock_attempts where user_id = auth.uid() for update;
  if v_att.locked_until is not null and v_att.locked_until > now() then
    raise exception 'Too many attempts. Try again after %',
      to_char(v_att.locked_until at time zone 'Asia/Karachi', 'HH24:MI') using errcode = '54000';
  end if;
  select secret_hash into v_hash from internal.private_secret where id = 1;
  if v_hash is null then
    raise exception 'PRIVATE_SECRET_NOT_SET' using errcode = '22023';
  end if;
  if p_secret is null or extensions.crypt(p_secret, v_hash) <> v_hash then
    insert into internal.unlock_attempts (user_id, failed_count, last_failed_at)
    values (auth.uid(), 1, now())
    on conflict (user_id) do update
       set failed_count = internal.unlock_attempts.failed_count + 1,
           last_failed_at = now(),
           locked_until = case when internal.unlock_attempts.failed_count + 1 >= 5
                               then now() + interval '15 minutes' end;
    perform internal.audit('private_unlock_failed', 'private_area', null);
    return jsonb_build_object('unlocked', false);
  end if;
  delete from internal.unlock_attempts where user_id = auth.uid();
  delete from internal.private_unlocks where expires_at <= now();
  v_exp := now() + interval '10 minutes';
  insert into internal.private_unlocks (session_id, user_id, expires_at)
  values (v_sid, auth.uid(), v_exp)
  on conflict (session_id) do update set expires_at = excluded.expires_at, unlocked_at = now();
  perform internal.audit('private_unlocked', 'private_area', null);
  return jsonb_build_object('unlocked', true, 'expires_at', v_exp);
end $$;

-- Sliding 10-minute inactivity window. Called by the app on owner activity.
create or replace function public.touch_private()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_exp timestamptz;
begin
  if not internal.is_owner_unlocked() then
    return jsonb_build_object('unlocked', false);
  end if;
  update internal.private_unlocks
     set expires_at = now() + interval '10 minutes'
   where session_id = internal.current_session_id()
  returning expires_at into v_exp;
  return jsonb_build_object('unlocked', true, 'expires_at', v_exp);
end $$;

create or replace function public.lock_private()
returns void language sql security definer set search_path = '' as $$
  delete from internal.private_unlocks
   where session_id = internal.current_session_id() or user_id = auth.uid()
$$;

-- =====================================================================
-- RPC: user management (owner + unlocked). Account creation / password
-- reset / ban use the "admin-users" Edge Function (service role).
-- =====================================================================
create or replace function public.owner_list_users()
returns table (id uuid, email text, full_name text, role public.user_role, is_active boolean,
               can_create_sale boolean, can_override_price boolean,
               last_sign_in_at timestamptz, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select p.id, u.email::text, p.full_name, p.role, p.is_active, p.can_create_sale,
           p.can_override_price, u.last_sign_in_at, p.created_at
      from public.profiles p join auth.users u on u.id = p.id
     order by p.role, p.full_name;
end $$;

create or replace function public.owner_set_user_access(
  p_user_id uuid, p_is_active boolean, p_can_create_sale boolean, p_can_override_price boolean,
  p_full_name text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_before jsonb; v_after jsonb;
begin
  perform internal.require_owner_unlocked();
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
         -- deactivation also revokes all current sessions
         sessions_valid_after = case when not p_is_active then now() else sessions_valid_after end
   where id = p_user_id
  returning to_jsonb(profiles.*) into v_after;
  perform internal.audit('user_access_changed', 'profile', p_user_id::text, null, v_before, v_after);
end $$;

create or replace function public.owner_revoke_sessions(p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  update public.profiles set sessions_valid_after = now() where id = p_user_id;
  if p_user_id = auth.uid() then
    delete from internal.private_unlocks where user_id = p_user_id;
  end if;
  perform internal.audit('sessions_revoked', 'profile', p_user_id::text);
end $$;

-- Lock down function execution
revoke execute on all functions in schema internal from public, anon, authenticated;
grant usage on schema internal to authenticated;  -- policies call internal.* helpers
grant execute on function
  internal.is_active_user(), internal.is_owner(), internal.is_owner_unlocked(),
  internal.has_permission(text), internal.jwt_claims(), internal.current_session_id(),
  internal.current_auth_time()
  to authenticated;

revoke execute on function public.private_status(), public.set_private_secret(text, text),
  public.unlock_private(text), public.touch_private(), public.lock_private(),
  public.owner_list_users(), public.owner_set_user_access(uuid, boolean, boolean, boolean, text),
  public.owner_revoke_sessions(uuid)
  from public, anon;
grant execute on function public.private_status(), public.set_private_secret(text, text),
  public.unlock_private(text), public.touch_private(), public.lock_private(),
  public.owner_list_users(), public.owner_set_user_access(uuid, boolean, boolean, boolean, text),
  public.owner_revoke_sessions(uuid)
  to authenticated;

-- Edge Functions (service role) write audit entries for account administration.
grant usage on schema private to service_role;
grant select, insert on private.audit_logs to service_role;
