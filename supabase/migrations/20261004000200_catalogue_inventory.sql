-- =====================================================================
-- Accessories Sahiwal — Stage 2a: Product catalogue, photos, stock ledger
-- Quantities are shared (public); costs/values are owner-only (private).
-- =====================================================================

create type public.stock_bucket as enum ('saleable', 'non_saleable');
create type public.movement_type as enum (
  'opening', 'purchase', 'sale', 'sale_return', 'sale_void',
  'purchase_return', 'adjustment_in', 'adjustment_out', 'damage');

-- ---------------------------------------------------------------------
-- Categories & products
-- ---------------------------------------------------------------------
create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(btrim(name)) between 1 and 80),
  is_active   boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);
create unique index categories_name_uq on public.categories (lower(btrim(name)));

create sequence public.product_code_seq start 1;

create table public.products (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null check (code ~ '^[A-Z0-9][A-Z0-9._/-]{0,39}$'),
  name                text not null check (char_length(btrim(name)) between 1 and 160),
  category_id         uuid references public.categories(id) on delete restrict,
  brand               text not null default '' check (char_length(brand) <= 80),
  model               text not null default '' check (char_length(model) <= 80),
  variant             text not null default '' check (char_length(variant) <= 80),
  description         text not null default '' check (char_length(description) <= 4000),
  wholesale_price     numeric(14,2) not null default 0 check (wholesale_price >= 0),
  retail_price        numeric(14,2) not null default 0 check (retail_price >= 0),
  warranty_note       text not null default '' check (char_length(warranty_note) <= 200),
  warranty_days       integer not null default 0 check (warranty_days between 0 and 3650),
  reorder_threshold   integer not null default 5 check (reorder_threshold >= 0),
  barcode             text check (barcode is null or char_length(barcode) <= 64),
  is_active           boolean not null default true,
  created_by          uuid references auth.users(id) on delete set null default auth.uid(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
-- Case-insensitive uniqueness after trimming (code is normalised to upper case by trigger)
create unique index products_code_uq on public.products (upper(btrim(code)));
create unique index products_barcode_uq on public.products (barcode) where barcode is not null;
create index products_name_idx on public.products (lower(name));
create index products_category_idx on public.products (category_id);

-- Normalise code; auto-generate AS-0001 style codes when blank.
create or replace function internal.products_normalise()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.code := upper(btrim(coalesce(new.code, '')));
  if new.code = '' then
    loop
      new.code := 'AS-' || lpad(nextval('public.product_code_seq')::text, 4, '0');
      exit when not exists (select 1 from public.products p where upper(btrim(p.code)) = new.code);
    end loop;
  end if;
  new.name := btrim(new.name);
  new.brand := btrim(coalesce(new.brand, ''));
  new.model := btrim(coalesce(new.model, ''));
  new.variant := btrim(coalesce(new.variant, ''));
  new.barcode := nullif(btrim(coalesce(new.barcode, '')), '');
  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;
  return new;
end $$;

-- Products are archived, never deleted once referenced (FKs use ON DELETE RESTRICT).
create or replace function internal.products_audit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.inventory_balances (product_id) values (new.id);
    insert into private.inventory_valuation (product_id) values (new.id);
    perform internal.audit('product_created', 'product', new.id::text, null, null, to_jsonb(new));
  elsif tg_op = 'UPDATE' then
    if (old.wholesale_price, old.retail_price, old.is_active, old.code, old.name)
       is distinct from (new.wholesale_price, new.retail_price, new.is_active, new.code, new.name) then
      perform internal.audit('product_updated', 'product', new.id::text, null,
        jsonb_build_object('code', old.code, 'name', old.name, 'wholesale_price', old.wholesale_price,
                           'retail_price', old.retail_price, 'is_active', old.is_active),
        jsonb_build_object('code', new.code, 'name', new.name, 'wholesale_price', new.wholesale_price,
                           'retail_price', new.retail_price, 'is_active', new.is_active));
    end if;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------
-- Product images (files live in private Storage bucket "product-images")
-- ---------------------------------------------------------------------
create table public.product_images (
  id            uuid primary key default gen_random_uuid(),
  product_id    uuid not null references public.products(id) on delete cascade,
  storage_path  text not null unique check (storage_path ~ '^products/[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|webp)$'),
  is_primary    boolean not null default false,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now()
);
create unique index product_images_one_primary on public.product_images (product_id) where is_primary;
create index product_images_product_idx on public.product_images (product_id, sort_order);

create or replace function internal.product_images_limit()
returns trigger language plpgsql set search_path = '' as $$
begin
  if (select count(*) from public.product_images where product_id = new.product_id) >= 5 then
    raise exception 'A product can have at most 5 photos' using errcode = '23514';
  end if;
  if new.storage_path not like 'products/' || new.product_id::text || '/%' then
    raise exception 'Image path does not belong to this product' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger product_images_limit before insert on public.product_images
  for each row execute function internal.product_images_limit();

-- ---------------------------------------------------------------------
-- Inventory: quantities (shared) and valuation (owner-only)
-- ---------------------------------------------------------------------
create table public.inventory_balances (
  product_id        uuid primary key references public.products(id) on delete restrict,
  saleable_qty      integer not null default 0 check (saleable_qty >= 0),
  non_saleable_qty  integer not null default 0 check (non_saleable_qty >= 0),
  version           bigint not null default 0,
  updated_at        timestamptz not null default now()
);

create table private.inventory_valuation (
  product_id      uuid primary key references public.products(id) on delete restrict,
  carrying_value  numeric(18,6) not null default 0 check (carrying_value >= 0),
  average_cost    numeric(18,6) not null default 0 check (average_cost >= 0),
  updated_at      timestamptz not null default now()
);

create table private.stock_movements (
  id              bigint generated always as identity primary key,
  product_id      uuid not null references public.products(id) on delete restrict,
  movement_type   public.movement_type not null,
  bucket          public.stock_bucket not null default 'saleable',
  quantity        integer not null check (quantity <> 0),          -- signed
  value_change    numeric(18,6) not null default 0,                -- signed carrying value change
  unit_cost       numeric(18,6) not null default 0 check (unit_cost >= 0),
  qty_after       integer not null check (qty_after >= 0),
  value_after     numeric(18,6) not null check (value_after >= 0),
  source_type     text not null,
  source_id       uuid,
  source_line_id  uuid,
  reason          text,
  actor_id        uuid references auth.users(id) on delete set null default auth.uid(),
  posted_at       timestamptz not null default now()
);
create index stock_movements_product_idx on private.stock_movements (product_id, posted_at desc);
create index stock_movements_source_idx on private.stock_movements (source_type, source_id);

create trigger products_normalise before insert or update on public.products
  for each row execute function internal.products_normalise();
create trigger products_audit after insert or update on public.products
  for each row execute function internal.products_audit();

-- Core inventory primitive: receive units into SALEABLE stock at a landed
-- value, updating the moving weighted-average cost. Caller must hold the
-- balance row lock (see internal.lock_balances).
create or replace function internal.receive_stock(
  p_product_id uuid, p_qty integer, p_value numeric, p_type public.movement_type,
  p_source_type text, p_source_id uuid, p_source_line_id uuid default null, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_bal public.inventory_balances; v_val private.inventory_valuation;
  v_new_qty integer; v_new_value numeric(18,6); v_avg numeric(18,6);
begin
  if p_qty is null or p_qty <= 0 then
    raise exception 'Quantity must be a positive whole number' using errcode = '22023';
  end if;
  if p_value is null or p_value < 0 then
    raise exception 'Cost cannot be negative' using errcode = '22023';
  end if;
  select * into v_bal from public.inventory_balances where product_id = p_product_id for update;
  select * into v_val from private.inventory_valuation where product_id = p_product_id for update;
  if v_bal.product_id is null then
    raise exception 'Product not found' using errcode = 'P0002';
  end if;
  v_new_qty := v_bal.saleable_qty + p_qty;
  v_new_value := v_val.carrying_value + p_value;
  -- (old qty × old avg + receipt landed cost) / (old qty + received qty)
  v_avg := round(v_new_value / v_new_qty, 6);

  update public.inventory_balances
     set saleable_qty = v_new_qty, version = version + 1, updated_at = now()
   where product_id = p_product_id;
  update private.inventory_valuation
     set carrying_value = v_new_value, average_cost = v_avg, updated_at = now()
   where product_id = p_product_id;
  insert into private.stock_movements
    (product_id, movement_type, bucket, quantity, value_change, unit_cost, qty_after, value_after,
     source_type, source_id, source_line_id, reason)
  values
    (p_product_id, p_type, 'saleable', p_qty, p_value, round(p_value / p_qty, 6), v_new_qty, v_new_value,
     p_source_type, p_source_id, p_source_line_id, p_reason);
end $$;

-- Lock balance rows in a consistent (product_id) order to avoid deadlocks.
create or replace function internal.lock_balances(p_product_ids uuid[])
returns void language sql security definer set search_path = '' as $$
  select 1 from public.inventory_balances
   where product_id = any(p_product_ids)
   order by product_id
   for update
$$;

-- =====================================================================
-- RLS
-- =====================================================================
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.product_images enable row level security;
alter table public.inventory_balances enable row level security;
alter table private.inventory_valuation enable row level security;
alter table private.stock_movements enable row level security;

create policy categories_select on public.categories for select to authenticated
  using ((select internal.is_active_user()));
create policy categories_owner_write on public.categories for all to authenticated
  using ((select internal.is_owner())) with check ((select internal.is_owner()));

create policy products_select on public.products for select to authenticated
  using ((select internal.is_active_user()));
create policy products_owner_insert on public.products for insert to authenticated
  with check ((select internal.is_owner()));
create policy products_owner_update on public.products for update to authenticated
  using ((select internal.is_owner())) with check ((select internal.is_owner()));

create policy product_images_select on public.product_images for select to authenticated
  using ((select internal.is_active_user()));
create policy product_images_owner_write on public.product_images for all to authenticated
  using ((select internal.is_owner())) with check ((select internal.is_owner()));

create policy balances_select on public.inventory_balances for select to authenticated
  using ((select internal.is_active_user()));
-- No write policies: balances change only through posting functions.

create policy valuation_select on private.inventory_valuation for select to authenticated
  using ((select internal.is_owner_unlocked()));
create policy movements_select on private.stock_movements for select to authenticated
  using ((select internal.is_owner_unlocked()));

revoke all on public.categories, public.products, public.product_images, public.inventory_balances from anon;
revoke all on public.categories, public.products, public.product_images, public.inventory_balances from authenticated;
grant select, insert, update, delete on public.categories to authenticated;
grant select, insert, update on public.products to authenticated;
grant select, insert, update, delete on public.product_images to authenticated;
grant select on public.inventory_balances to authenticated;
grant select on private.inventory_valuation, private.stock_movements to authenticated;
grant usage on sequence public.product_code_seq to authenticated;

-- =====================================================================
-- RPC: shared (owner + partner)
-- =====================================================================

-- Exact code (or barcode) lookup → product details, stock and selling prices. No cost.
create or replace function public.lookup_product(p_code text)
returns table (id uuid, code text, name text, category_name text, brand text, model text,
               variant text, description text, wholesale_price numeric, retail_price numeric,
               warranty_note text, warranty_days integer, saleable_qty integer,
               reorder_threshold integer, is_active boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_active();
  return query
    select p.id, p.code, p.name, c.name, p.brand, p.model, p.variant, p.description,
           p.wholesale_price, p.retail_price, p.warranty_note, p.warranty_days,
           b.saleable_qty, p.reorder_threshold, p.is_active
      from public.products p
      join public.inventory_balances b on b.product_id = p.id
      left join public.categories c on c.id = p.category_id
     where upper(btrim(p.code)) = upper(btrim(p_code))
        or p.barcode = btrim(p_code)
     limit 1;
end $$;

-- Stock list with search/filters. Quantities only — safe for partners.
create or replace function public.stock_list(
  p_search text default null, p_category_id uuid default null,
  p_low_only boolean default false, p_include_inactive boolean default false)
returns table (product_id uuid, code text, name text, category_name text, brand text,
               saleable_qty integer, non_saleable_qty integer, reorder_threshold integer,
               is_low boolean, wholesale_price numeric, retail_price numeric, is_active boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_active();
  return query
    select p.id, p.code, p.name, c.name, p.brand, b.saleable_qty, b.non_saleable_qty,
           p.reorder_threshold, b.saleable_qty <= p.reorder_threshold,
           p.wholesale_price, p.retail_price, p.is_active
      from public.products p
      join public.inventory_balances b on b.product_id = p.id
      left join public.categories c on c.id = p.category_id
     where (p_include_inactive or p.is_active)
       and (p_category_id is null or p.category_id = p_category_id)
       and (not p_low_only or b.saleable_qty <= p.reorder_threshold)
       and (p_search is null or btrim(p_search) = ''
            or p.code ilike '%' || btrim(p_search) || '%'
            or p.name ilike '%' || btrim(p_search) || '%'
            or p.brand ilike '%' || btrim(p_search) || '%'
            or p.model ilike '%' || btrim(p_search) || '%')
     order by (b.saleable_qty <= p.reorder_threshold) desc, p.name
     limit 500;
end $$;

-- Movement history safe for partners: no values, costs, suppliers or reasons.
create or replace function public.stock_movement_history(p_product_id uuid, p_limit integer default 100)
returns table (posted_at timestamptz, movement_type public.movement_type,
               bucket public.stock_bucket, quantity integer, qty_after integer)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_active();
  return query
    select m.posted_at, m.movement_type, m.bucket, m.quantity, m.qty_after
      from private.stock_movements m
     where m.product_id = p_product_id
     order by m.posted_at desc, m.id desc
     limit least(greatest(coalesce(p_limit, 100), 1), 500);
end $$;

-- =====================================================================
-- RPC: owner-only stock valuation
-- =====================================================================
create or replace function public.owner_stock_valuation(p_search text default null)
returns table (product_id uuid, code text, name text, saleable_qty integer,
               average_cost numeric, carrying_value numeric,
               retail_price numeric, wholesale_price numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select p.id, p.code, p.name, b.saleable_qty, v.average_cost,
           round(v.carrying_value, 2), p.retail_price, p.wholesale_price
      from public.products p
      join public.inventory_balances b on b.product_id = p.id
      join private.inventory_valuation v on v.product_id = p.id
     where p_search is null or btrim(p_search) = ''
        or p.code ilike '%' || btrim(p_search) || '%' or p.name ilike '%' || btrim(p_search) || '%'
     order by p.name;
end $$;

revoke execute on function public.lookup_product(text), public.stock_list(text, uuid, boolean, boolean),
  public.stock_movement_history(uuid, integer), public.owner_stock_valuation(text) from public, anon;
grant execute on function public.lookup_product(text), public.stock_list(text, uuid, boolean, boolean),
  public.stock_movement_history(uuid, integer), public.owner_stock_valuation(text) to authenticated;
revoke execute on all functions in schema internal from public, anon, authenticated;
grant execute on function
  internal.is_active_user(), internal.is_owner(), internal.is_owner_unlocked(),
  internal.has_permission(text), internal.jwt_claims(), internal.current_session_id(),
  internal.current_auth_time()
  to authenticated;

-- =====================================================================
-- Storage: private bucket for product photos (5 MB, JPEG/PNG/WebP)
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', false, 5242880,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('branding', 'branding', false, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "product images readable by active users" on storage.objects
  for select to authenticated
  using (bucket_id in ('product-images', 'branding') and (select internal.is_active_user()));
create policy "product images owner insert" on storage.objects
  for insert to authenticated
  with check (bucket_id in ('product-images', 'branding') and (select internal.is_owner()));
create policy "product images owner update" on storage.objects
  for update to authenticated
  using (bucket_id in ('product-images', 'branding') and (select internal.is_owner()));
create policy "product images owner delete" on storage.objects
  for delete to authenticated
  using (bucket_id in ('product-images', 'branding') and (select internal.is_owner()));
