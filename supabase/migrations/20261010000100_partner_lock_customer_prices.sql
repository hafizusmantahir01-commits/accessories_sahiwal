-- =====================================================================
-- 1) Full-access partner also works behind the lock: they unlock with their
--    OWN login password (the app signs them in again, then calls
--    unlock_with_login within 2 minutes). Same 10-minute sliding lock.
-- 2) Customer price memory: the last price each shopkeeper paid per product.
-- =====================================================================

create or replace function internal.is_owner_unlocked()
returns boolean language sql stable security definer set search_path = '' as $$
  select (internal.is_real_owner() or internal.is_full_partner()) and exists (
    select 1 from internal.private_unlocks u
     where u.session_id = internal.current_session_id()
       and u.user_id = auth.uid()
       and u.expires_at > now()
  )
$$;

create or replace function public.private_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_exp timestamptz; v_has_secret boolean;
begin
  if internal.is_real_owner_any_device() then
    select expires_at into v_exp from internal.private_unlocks
     where session_id = internal.current_session_id() and user_id = auth.uid() and expires_at > now();
    v_has_secret := exists (select 1 from internal.private_secret);
    return jsonb_build_object('is_owner', true, 'unlocked', v_exp is not null,
                              'expires_at', v_exp, 'has_secret', v_has_secret);
  end if;
  if internal.is_full_partner() then
    select expires_at into v_exp from internal.private_unlocks
     where session_id = internal.current_session_id() and user_id = auth.uid() and expires_at > now();
    -- is_owner stays false so the admin-users function keeps refusing partners.
    return jsonb_build_object('is_owner', false, 'full_access', true, 'unlocked', v_exp is not null,
                              'expires_at', v_exp, 'has_secret', true);
  end if;
  return jsonb_build_object('is_owner', false, 'unlocked', false, 'has_secret', false);
end $$;

-- Partner unlock: only right after signing in again with their password.
create or replace function public.unlock_with_login()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_sid uuid := internal.current_session_id(); v_exp timestamptz;
begin
  if not internal.is_full_partner() then
    raise exception 'Owner access required' using errcode = '42501';
  end if;
  if v_sid is null or internal.current_auth_time() < now() - interval '2 minutes' then
    raise exception 'Enter your password again to unlock' using errcode = '42501';
  end if;
  delete from internal.private_unlocks where expires_at <= now();
  v_exp := now() + interval '10 minutes';
  insert into internal.private_unlocks (session_id, user_id, expires_at)
  values (v_sid, auth.uid(), v_exp)
  on conflict (session_id) do update set expires_at = excluded.expires_at, unlocked_at = now();
  perform internal.audit('private_unlocked', 'private_area', null, 'partner (login password)');
  return jsonb_build_object('unlocked', true, 'expires_at', v_exp);
end $$;

-- Last price each product was sold to this shopkeeper (latest completed sale).
create or replace function public.customer_last_prices(p_customer_id uuid)
returns table (product_id uuid, unit_price numeric, sold_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not internal.has_permission('create_sale') then
    raise exception 'Not authorised' using errcode = '42501';
  end if;
  return query
    select distinct on (i.product_id) i.product_id, i.unit_price, s.completed_at
      from public.sale_items i join public.sales s on s.id = i.sale_id
     where s.customer_id = p_customer_id and s.status = 'completed'
     order by i.product_id, s.completed_at desc;
end $$;

revoke execute on function public.unlock_with_login(), public.customer_last_prices(uuid) from public, anon;
grant execute on function public.unlock_with_login(), public.customer_last_prices(uuid) to authenticated;
