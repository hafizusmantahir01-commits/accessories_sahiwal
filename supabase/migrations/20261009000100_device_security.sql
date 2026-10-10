-- =====================================================================
-- Device approval + security alerts
--  * Every app install has a device id (sent in the "x-device-id" header).
--  * A device must be APPROVED before its account can read or change data.
--    - The owner's very first device is approved automatically.
--    - Any other new device (owner or partner) waits for approval.
--      The owner can approve their own new device by typing the private
--      password on it, or approve/block any device from Devices & security.
--  * Failed logins, new devices and blocked-device attempts are recorded as
--    security events; the owner's app shows an alert for unseen events.
-- =====================================================================

alter table public.business_settings
  add column if not exists device_approval boolean not null default true;

create table if not exists private.devices (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  device_id   text not null check (char_length(device_id) between 8 and 100),
  label       text not null default '' check (char_length(label) <= 200),
  status      text not null default 'pending' check (status in ('pending', 'approved', 'blocked')),
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  last_ip     text,
  decided_at  timestamptz,
  unique (user_id, device_id)
);

create table if not exists private.security_events (
  id           bigserial primary key,
  created_at   timestamptz not null default now(),
  kind         text not null,  -- failed_login | new_device | blocked_device_attempt | device_approved | device_blocked
  email        text,
  user_id      uuid,
  device_id    text,
  device_label text,
  ip           text,
  seen         boolean not null default false
);
create index if not exists security_events_recent on private.security_events (created_at desc);

alter table private.devices enable row level security;
alter table private.security_events enable row level security;
revoke all on private.devices, private.security_events from anon, authenticated;

-- ---------------------------------------------------------------------
-- Request helpers
-- ---------------------------------------------------------------------
create or replace function internal.request_headers()
returns json language sql stable set search_path = '' as $$
  select coalesce(nullif(current_setting('request.headers', true), ''), '{}')::json
$$;

create or replace function internal.current_device_id()
returns text language sql stable set search_path = '' as $$
  select nullif(btrim(internal.request_headers() ->> 'x-device-id'), '')
$$;

create or replace function internal.request_ip()
returns text language sql stable set search_path = '' as $$
  select left(coalesce(nullif(internal.request_headers() ->> 'cf-connecting-ip', ''),
                       nullif(btrim(split_part(internal.request_headers() ->> 'x-forwarded-for', ',', 1)), '')), 60)
$$;

create or replace function internal.device_allowed()
returns boolean language sql stable security definer set search_path = '' as $$
  select not coalesce((select device_approval from public.business_settings where id = 1), false)
      or exists (select 1 from private.devices d
                  where d.user_id = auth.uid()
                    and d.device_id = internal.current_device_id()
                    and d.status = 'approved')
$$;

-- Owner identity WITHOUT the device check (only for private_status, which
-- reports "unlocked" — and unlocking itself needs an approved device).
create or replace function internal.is_real_owner_any_device()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
     where p.id = auth.uid() and p.role = 'owner' and p.is_active
       and internal.current_auth_time() >= p.sessions_valid_after)
$$;

-- ---------------------------------------------------------------------
-- Access helpers now also require an approved device
-- ---------------------------------------------------------------------
create or replace function internal.is_active_user()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
     where p.id = auth.uid()
       and p.is_active
       and internal.current_auth_time() >= p.sessions_valid_after
  ) and internal.device_allowed()
$$;

create or replace function internal.is_real_owner()
returns boolean language sql stable security definer set search_path = '' as $$
  select internal.is_real_owner_any_device() and internal.device_allowed()
$$;

create or replace function internal.is_full_partner()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
     where p.id = auth.uid() and p.role = 'partner' and p.is_active and p.full_access
       and internal.current_auth_time() >= p.sessions_valid_after
  ) and internal.device_allowed()
$$;

create or replace function internal.has_permission(p_permission text)
returns boolean language sql stable security definer set search_path = '' as $$
  select internal.is_owner() or (internal.is_active_user() and exists (
    select 1 from public.profiles p
     where p.id = auth.uid()
       and case p_permission
             when 'create_sale'    then p.can_create_sale
             when 'override_price' then p.can_override_price
             else false
           end
  ))
$$;

create or replace function public.private_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_exp timestamptz; v_has_secret boolean;
begin
  if not internal.is_real_owner_any_device() then
    return jsonb_build_object('is_owner', false, 'unlocked', internal.is_full_partner(),
                              'has_secret', true, 'full_access', internal.is_full_partner());
  end if;
  select expires_at into v_exp from internal.private_unlocks
   where session_id = internal.current_session_id() and user_id = auth.uid() and expires_at > now();
  v_has_secret := exists (select 1 from internal.private_secret);
  return jsonb_build_object('is_owner', true, 'unlocked', v_exp is not null,
                            'expires_at', v_exp, 'has_secret', v_has_secret);
end $$;

-- ---------------------------------------------------------------------
-- Device registration (called by the app right after sign-in)
-- ---------------------------------------------------------------------
create or replace function public.register_device(p_label text default '')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_dev text := internal.current_device_id();
  v_prof public.profiles;
  v_row private.devices;
  v_status text;
  v_email text;
  v_required boolean := coalesce((select device_approval from public.business_settings where id = 1), false);
begin
  select * into v_prof from public.profiles where id = auth.uid();
  if v_prof.id is null or not v_prof.is_active then
    return jsonb_build_object('status', 'inactive', 'required', v_required);
  end if;
  if v_dev is null or char_length(v_dev) < 8 then
    raise exception 'DEVICE_ID_MISSING' using errcode = '22023';
  end if;
  select email into v_email from auth.users where id = auth.uid();

  select * into v_row from private.devices where user_id = auth.uid() and device_id = v_dev for update;
  if v_row.id is not null then
    update private.devices
       set last_seen = now(), last_ip = internal.request_ip(),
           label = coalesce(nullif(left(btrim(p_label), 200), ''), label)
     where id = v_row.id;
    if v_row.status = 'blocked' then
      insert into private.security_events (kind, email, user_id, device_id, device_label, ip)
      values ('blocked_device_attempt', v_email, auth.uid(), v_dev, v_row.label, internal.request_ip());
    end if;
    return jsonb_build_object('status', case when v_required then v_row.status else 'approved' end,
                              'required', v_required);
  end if;

  v_status := case
    when not v_required then 'approved'
    when v_prof.role = 'owner' and not exists (
      select 1 from private.devices d where d.user_id = auth.uid() and d.status = 'approved') then 'approved'
    else 'pending' end;

  insert into private.devices (user_id, device_id, label, status, last_ip, decided_at)
  values (auth.uid(), v_dev, left(coalesce(btrim(p_label), ''), 200), v_status, internal.request_ip(),
          case when v_status = 'approved' then now() end);
  insert into private.security_events (kind, email, user_id, device_id, device_label, ip, seen)
  values ('new_device', v_email, auth.uid(), v_dev, left(coalesce(btrim(p_label), ''), 200), internal.request_ip(),
          v_status = 'approved' and v_prof.role = 'owner');
  return jsonb_build_object('status', v_status, 'required', v_required);
end $$;

-- Owner approves THEIR OWN new device by typing the private password on it.
create or replace function public.approve_own_device(p_secret text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_dev text := internal.current_device_id(); v_hash text; v_att internal.unlock_attempts;
begin
  if not internal.is_real_owner_any_device() then
    raise exception 'Only the owner can approve a device this way' using errcode = '42501';
  end if;
  select * into v_att from internal.unlock_attempts where user_id = auth.uid() for update;
  if v_att.locked_until is not null and v_att.locked_until > now() then
    raise exception 'Too many attempts. Try again after %',
      to_char(v_att.locked_until at time zone 'Asia/Karachi', 'HH24:MI') using errcode = '54000';
  end if;
  select secret_hash into v_hash from internal.private_secret where id = 1;
  if v_hash is null or p_secret is null or extensions.crypt(p_secret, v_hash) <> v_hash then
    insert into internal.unlock_attempts (user_id, failed_count, last_failed_at)
    values (auth.uid(), 1, now())
    on conflict (user_id) do update
       set failed_count = internal.unlock_attempts.failed_count + 1, last_failed_at = now(),
           locked_until = case when internal.unlock_attempts.failed_count + 1 >= 5
                               then now() + interval '15 minutes' end;
    insert into private.security_events (kind, email, user_id, device_id, ip)
    select 'failed_device_approval', u.email, auth.uid(), v_dev, internal.request_ip() from auth.users u where u.id = auth.uid();
    return jsonb_build_object('approved', false);
  end if;
  delete from internal.unlock_attempts where user_id = auth.uid();
  update private.devices set status = 'approved', decided_at = now()
   where user_id = auth.uid() and device_id = v_dev and status = 'pending';
  if not found then
    raise exception 'This device is blocked or not registered' using errcode = '42501';
  end if;
  perform internal.audit('device_approved', 'device', v_dev, 'approved with private password');
  return jsonb_build_object('approved', true);
end $$;

-- Called by the login screen when sign-in fails (works without a session).
create or replace function public.report_login_failure(p_email text, p_label text default '')
returns void language plpgsql security definer set search_path = '' as $$
declare v_dev text := internal.current_device_id(); v_ip text := internal.request_ip(); v_email text;
begin
  v_email := left(lower(btrim(coalesce(p_email, ''))), 200);
  -- Rate limit: at most 30 records per device/IP per hour.
  if (select count(*) from private.security_events
       where kind = 'failed_login' and created_at > now() - interval '1 hour'
         and ((v_dev is not null and device_id = v_dev) or (v_ip is not null and ip = v_ip))) >= 30 then
    return;
  end if;
  insert into private.security_events (kind, email, user_id, device_id, device_label, ip)
  values ('failed_login', nullif(v_email, ''),
          (select id from auth.users where lower(email) = v_email limit 1),
          v_dev, left(coalesce(btrim(p_label), ''), 200), v_ip);
end $$;

-- ---------------------------------------------------------------------
-- Owner: alerts and device management
-- ---------------------------------------------------------------------
create or replace function public.owner_security_summary()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not internal.is_real_owner() then
    return jsonb_build_object('unseen', 0, 'pending_devices', 0);
  end if;
  return jsonb_build_object(
    'approval_required', coalesce((select device_approval from public.business_settings where id = 1), false),
    'unseen', (select count(*) from private.security_events where not seen),
    'pending_devices', (select count(*) from private.devices where status = 'pending'),
    'latest', (select jsonb_build_object('kind', kind, 'email', email, 'device_label', device_label, 'created_at', created_at)
                 from private.security_events where not seen order by created_at desc limit 1));
end $$;

create or replace function public.owner_security_events(p_limit integer default 200)
returns table (id bigint, created_at timestamptz, kind text, email text, user_name text,
               device_label text, ip text, seen boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_real_owner_unlocked();
  return query
    select e.id, e.created_at, e.kind, e.email, coalesce(nullif(p.full_name, ''), e.email, 'Unknown'),
           e.device_label, e.ip, e.seen
      from private.security_events e left join public.profiles p on p.id = e.user_id
     order by e.created_at desc, e.id desc
     limit least(greatest(coalesce(p_limit, 200), 1), 1000);
end $$;

create or replace function public.owner_mark_security_seen()
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform internal.require_real_owner_unlocked();
  update private.security_events set seen = true where not seen;
end $$;

create or replace function public.owner_list_devices()
returns table (id uuid, user_id uuid, user_name text, user_role text, label text, status text,
               first_seen timestamptz, last_seen timestamptz, last_ip text, is_current boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_real_owner_unlocked();
  return query
    select d.id, d.user_id, coalesce(nullif(p.full_name, ''), u.email::text), p.role::text, d.label, d.status,
           d.first_seen, d.last_seen, d.last_ip,
           (d.user_id = auth.uid() and d.device_id = internal.current_device_id())
      from private.devices d
      join public.profiles p on p.id = d.user_id
      join auth.users u on u.id = d.user_id
     order by (d.status = 'pending') desc, d.last_seen desc;
end $$;

create or replace function public.owner_set_device_status(p_device uuid, p_status text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_row private.devices;
begin
  perform internal.require_real_owner_unlocked();
  if p_status not in ('approved', 'blocked') then
    raise exception 'Unknown status' using errcode = '22023';
  end if;
  select * into v_row from private.devices where id = p_device for update;
  if v_row.id is null then
    raise exception 'Device not found' using errcode = 'P0002';
  end if;
  if p_status = 'blocked' and v_row.user_id = auth.uid() and v_row.device_id = internal.current_device_id() then
    raise exception 'You cannot block the device you are using right now' using errcode = '42501';
  end if;
  update private.devices set status = p_status, decided_at = now() where id = p_device;
  insert into private.security_events (kind, email, user_id, device_id, device_label, ip, seen)
  select case when p_status = 'approved' then 'device_approved' else 'device_blocked' end,
         u.email, v_row.user_id, v_row.device_id, v_row.label, internal.request_ip(), true
    from auth.users u where u.id = v_row.user_id;
  perform internal.audit(case when p_status = 'approved' then 'device_approved' else 'device_blocked' end,
                         'device', p_device::text, v_row.label);
end $$;

create or replace function public.owner_delete_device(p_device uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_row private.devices;
begin
  perform internal.require_real_owner_unlocked();
  select * into v_row from private.devices where id = p_device;
  if v_row.id is null then return; end if;
  if v_row.user_id = auth.uid() and v_row.device_id = internal.current_device_id() then
    raise exception 'You cannot remove the device you are using right now' using errcode = '42501';
  end if;
  delete from private.devices where id = p_device;
  perform internal.audit('device_removed', 'device', p_device::text, v_row.label);
end $$;

create or replace function public.owner_set_device_approval(p_enabled boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform internal.require_real_owner_unlocked();
  if p_enabled then
    -- Make sure the owner's current device is approved before switching on.
    insert into private.devices (user_id, device_id, label, status, decided_at)
    select auth.uid(), internal.current_device_id(), 'This device', 'approved', now()
     where internal.current_device_id() is not null
    on conflict (user_id, device_id) do update set status = 'approved', decided_at = now();
  end if;
  update public.business_settings set device_approval = coalesce(p_enabled, true) where id = 1;
  perform internal.audit(case when p_enabled then 'device_approval_on' else 'device_approval_off' end, 'settings', '1');
end $$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
revoke execute on function internal.request_headers(), internal.current_device_id(), internal.request_ip(),
  internal.device_allowed(), internal.is_real_owner_any_device() from public, anon;
grant execute on function internal.request_headers(), internal.current_device_id(), internal.request_ip(),
  internal.device_allowed(), internal.is_real_owner_any_device() to authenticated;

revoke execute on function public.register_device(text), public.approve_own_device(text),
  public.owner_security_summary(), public.owner_security_events(integer), public.owner_mark_security_seen(),
  public.owner_list_devices(), public.owner_set_device_status(uuid, text), public.owner_delete_device(uuid),
  public.owner_set_device_approval(boolean) from public, anon;
grant execute on function public.register_device(text), public.approve_own_device(text),
  public.owner_security_summary(), public.owner_security_events(integer), public.owner_mark_security_seen(),
  public.owner_list_devices(), public.owner_set_device_status(uuid, text), public.owner_delete_device(uuid),
  public.owner_set_device_approval(boolean) to authenticated;

revoke execute on function public.report_login_failure(text, text) from public;
grant execute on function public.report_login_failure(text, text) to anon, authenticated;
