-- =====================================================================
-- Accessories Sahiwal — Stage 3: product delete, activity history, sales
--   * Owner can delete a product that has never been used in stock/sales.
--   * Activity history (who did what) for the owner.
--   * Wholesale + retail sales, fully paid, with an optional negotiated
--     final amount (e.g. bill 10,050 → shopkeeper pays 10,000; the 50 is a
--     recorded discount with a reason, so profit stays exact).
-- =====================================================================

create type public.sale_type as enum ('wholesale', 'retail');
create type public.sale_status as enum ('completed', 'voided');
create type public.customer_type as enum ('shopkeeper', 'retail');

-- ---------------------------------------------------------------------
-- Customers (shopkeepers and saved retail customers)
-- ---------------------------------------------------------------------
create table public.customers (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (char_length(btrim(name)) between 1 and 120),
  phone          text not null default '' check (char_length(phone) <= 40),
  address        text not null default '' check (char_length(address) <= 300),
  customer_type  public.customer_type not null default 'shopkeeper',
  is_active      boolean not null default true,
  created_by     uuid references auth.users(id) on delete set null default auth.uid(),
  created_at     timestamptz not null default now()
);
create index customers_name_idx on public.customers (lower(name));

-- ---------------------------------------------------------------------
-- Sales (visible to owner + partner; NO cost columns here)
-- ---------------------------------------------------------------------
create sequence public.invoice_no_seq start 1;

create table public.sales (
  id                 uuid primary key default gen_random_uuid(),
  invoice_no         text not null unique,
  sale_type          public.sale_type not null,
  status             public.sale_status not null default 'completed',
  customer_id        uuid references public.customers(id) on delete set null,
  customer_name      text not null default '',
  customer_phone     text not null default '',
  subtotal           numeric(14,2) not null check (subtotal >= 0),
  discount_amount    numeric(14,2) not null default 0 check (discount_amount >= 0),
  discount_reason    text not null default '',
  total              numeric(14,2) not null check (total >= 0),
  payment_method     public.payment_method not null,
  amount_tendered    numeric(14,2) not null check (amount_tendered >= 0),
  change_given       numeric(14,2) not null default 0 check (change_given >= 0),
  payment_reference  text not null default '',
  notes              text not null default '',
  idempotency_key    uuid not null unique,
  created_by         uuid references auth.users(id) on delete set null default auth.uid(),
  completed_at       timestamptz not null default now(),
  voided_at          timestamptz,
  voided_by          uuid references auth.users(id) on delete set null,
  void_reason        text,
  check (total = subtotal - discount_amount),
  check (amount_tendered >= total),
  check ((status = 'voided') = (voided_at is not null))
);
create index sales_completed_idx on public.sales (completed_at desc);
create index sales_customer_idx on public.sales (customer_id);

create table public.sale_items (
  id                 uuid primary key default gen_random_uuid(),
  sale_id            uuid not null references public.sales(id) on delete restrict,
  line_no            integer not null check (line_no > 0),
  product_id         uuid not null references public.products(id) on delete restrict,
  product_code       text not null,
  product_name       text not null,
  quantity           integer not null check (quantity > 0),
  list_price         numeric(14,2) not null check (list_price >= 0),
  unit_price         numeric(14,2) not null check (unit_price >= 0),
  line_total         numeric(14,2) not null check (line_total >= 0),
  discount_share     numeric(14,2) not null default 0 check (discount_share >= 0),
  net_total          numeric(14,2) not null check (net_total >= 0),
  warranty_note      text not null default '',
  warranty_days      integer not null default 0,
  unique (sale_id, line_no)
);
create index sale_items_product_idx on public.sale_items (product_id);

-- Owner-only cost snapshot (COGS) per sale line.
create table private.sale_costs (
  sale_item_id  uuid primary key references public.sale_items(id) on delete restrict,
  sale_id       uuid not null references public.sales(id) on delete restrict,
  product_id    uuid not null references public.products(id) on delete restrict,
  quantity      integer not null check (quantity > 0),
  unit_cost     numeric(18,6) not null check (unit_cost >= 0),
  cost_total    numeric(18,6) not null check (cost_total >= 0)
);
create index sale_costs_sale_idx on private.sale_costs (sale_id);

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.customers enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table private.sale_costs enable row level security;

create policy customers_select on public.customers for select to authenticated
  using ((select internal.is_active_user()));
create policy customers_insert on public.customers for insert to authenticated
  with check ((select internal.has_permission('create_sale')));
create policy customers_owner_update on public.customers for update to authenticated
  using ((select internal.is_owner())) with check ((select internal.is_owner()));

create policy sales_select on public.sales for select to authenticated
  using ((select internal.is_active_user()));
create policy sale_items_select on public.sale_items for select to authenticated
  using ((select internal.is_active_user()));
create policy sale_costs_select on private.sale_costs for select to authenticated
  using ((select internal.is_owner_unlocked()));

revoke all on public.customers, public.sales, public.sale_items from anon, authenticated;
revoke all on private.sale_costs from anon, authenticated;
grant select, insert, update on public.customers to authenticated;
grant select on public.sales, public.sale_items to authenticated;
grant select on private.sale_costs to authenticated;

-- ---------------------------------------------------------------------
-- Internal: issue units from saleable stock at moving-average cost.
-- Returns the cost (COGS) of the issued units. Caller holds row locks.
-- ---------------------------------------------------------------------
create or replace function internal.issue_stock(
  p_product_id uuid, p_qty integer, p_type public.movement_type,
  p_source_type text, p_source_id uuid, p_source_line_id uuid default null, p_reason text default null)
returns numeric language plpgsql security definer set search_path = '' as $$
declare
  v_bal public.inventory_balances; v_val private.inventory_valuation;
  v_cost numeric(18,6); v_code text;
begin
  if p_qty is null or p_qty <= 0 then
    raise exception 'Quantity must be a positive whole number' using errcode = '22023';
  end if;
  select * into v_bal from public.inventory_balances where product_id = p_product_id for update;
  select * into v_val from private.inventory_valuation where product_id = p_product_id for update;
  if v_bal.product_id is null then
    raise exception 'Product not found' using errcode = 'P0002';
  end if;
  if v_bal.saleable_qty < p_qty then
    select code into v_code from public.products where id = p_product_id;
    raise exception 'INSUFFICIENT_STOCK: Only % in stock for %', v_bal.saleable_qty, v_code
      using errcode = '23514';
  end if;
  if p_qty = v_bal.saleable_qty then
    v_cost := v_val.carrying_value;                 -- last units take the remaining value
  else
    v_cost := least(round(p_qty * v_val.average_cost, 6), v_val.carrying_value);
  end if;

  update public.inventory_balances
     set saleable_qty = saleable_qty - p_qty, version = version + 1, updated_at = now()
   where product_id = p_product_id;
  update private.inventory_valuation
     set carrying_value = carrying_value - v_cost, updated_at = now()
   where product_id = p_product_id;
  insert into private.stock_movements
    (product_id, movement_type, bucket, quantity, value_change, unit_cost, qty_after, value_after,
     source_type, source_id, source_line_id, reason)
  values
    (p_product_id, p_type, 'saleable', -p_qty, -v_cost, v_val.average_cost,
     v_bal.saleable_qty - p_qty, v_val.carrying_value - v_cost,
     p_source_type, p_source_id, p_source_line_id, p_reason);
  return v_cost;
end $$;

-- =====================================================================
-- RPC: complete a sale (fully paid, atomic, idempotent)
-- p_data: {
--   sale_type: 'wholesale'|'retail',
--   customer_id?, customer_name?, customer_phone?, save_customer?: bool,
--   items: [{ product_id, quantity, unit_price? }],
--   final_amount?: number   -- negotiated amount; difference = discount
--   discount_reason?: text,
--   payment_method, amount_tendered?, payment_reference?, notes?,
--   allow_below_cost?: bool (owner only), below_cost_reason?: text
-- }
-- =====================================================================
create or replace function public.complete_sale(p_data jsonb, p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_existing public.sales;
  v_type public.sale_type;
  v_is_owner boolean := internal.is_owner();
  v_can_price boolean := internal.has_permission('override_price');
  v_customer_id uuid := nullif(p_data ->> 'customer_id', '')::uuid;
  v_customer_name text := btrim(coalesce(p_data ->> 'customer_name', ''));
  v_customer_phone text := btrim(coalesce(p_data ->> 'customer_phone', ''));
  v_item jsonb; v_line integer := 0;
  v_subtotal numeric(14,2) := 0; v_discount numeric(14,2) := 0; v_total numeric(14,2);
  v_final numeric; v_reason text := btrim(coalesce(p_data ->> 'discount_reason', ''));
  v_method public.payment_method;
  v_tendered numeric(14,2); v_change numeric(14,2) := 0;
  v_sale_id uuid := gen_random_uuid(); v_invoice text;
  v_alloc_sum numeric(14,2); v_cost numeric; v_below boolean := false;
  r record;
begin
  if not internal.has_permission('create_sale') then
    raise exception 'You do not have permission to create sales' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'Missing idempotency key' using errcode = '22023';
  end if;
  -- Serialise retries of the same request.
  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text, 0));
  select * into v_existing from public.sales where idempotency_key = p_idempotency_key;
  if v_existing.id is not null then
    return jsonb_build_object('id', v_existing.id, 'invoice_no', v_existing.invoice_no,
      'total', v_existing.total, 'change', v_existing.change_given, 'already_posted', true);
  end if;

  v_type := (p_data ->> 'sale_type')::public.sale_type;
  v_method := coalesce(nullif(p_data ->> 'payment_method', ''), 'cash')::public.payment_method;
  if jsonb_typeof(p_data -> 'items') is distinct from 'array' or jsonb_array_length(p_data -> 'items') = 0 then
    raise exception 'Add at least one product' using errcode = '22023';
  end if;

  -- Customer
  if v_customer_id is not null then
    select name, phone into v_customer_name, v_customer_phone
      from public.customers where id = v_customer_id;
    if v_customer_name is null then
      raise exception 'Customer not found' using errcode = 'P0002';
    end if;
  elsif v_customer_name <> '' and coalesce((p_data ->> 'save_customer')::boolean, v_type = 'wholesale') then
    insert into public.customers (name, phone, customer_type)
    values (v_customer_name, v_customer_phone,
            case when v_type = 'wholesale' then 'shopkeeper' else 'retail' end::public.customer_type)
    returning id into v_customer_id;
  end if;
  if v_type = 'wholesale' and v_customer_name = '' then
    raise exception 'Select or enter the shopkeeper for a wholesale sale' using errcode = '22023';
  end if;

  -- Lines (temporary working table)
  create temporary table if not exists pg_temp.sale_lines (
    line_no int, product_id uuid, code text, name text, qty int, list_price numeric(14,2),
    unit_price numeric(14,2), line_total numeric(14,2), share numeric(14,2) default 0,
    warranty_note text, warranty_days int, avg_cost numeric(18,6)
  ) on commit drop;
  delete from pg_temp.sale_lines where line_no is not null or line_no is null;

  for v_item in select * from jsonb_array_elements(p_data -> 'items') loop
    v_line := v_line + 1;
    if (v_item ->> 'quantity')::numeric <> trunc((v_item ->> 'quantity')::numeric)
       or (v_item ->> 'quantity')::numeric <= 0 then
      raise exception 'Line %: quantity must be a positive whole number', v_line using errcode = '22023';
    end if;
    insert into pg_temp.sale_lines (line_no, product_id, code, name, qty, list_price, unit_price,
                                    warranty_note, warranty_days, avg_cost)
    select v_line, p.id, p.code, p.name, (v_item ->> 'quantity')::int,
           case when v_type = 'wholesale' then p.wholesale_price else p.retail_price end,
           coalesce(nullif(v_item ->> 'unit_price', '')::numeric,
                    case when v_type = 'wholesale' then p.wholesale_price else p.retail_price end),
           p.warranty_note, p.warranty_days, iv.average_cost
      from public.products p join private.inventory_valuation iv on iv.product_id = p.id
     where p.id = (v_item ->> 'product_id')::uuid and p.is_active;
    if not found then
      raise exception 'Line %: product not found or archived', v_line using errcode = 'P0002';
    end if;
  end loop;

  if exists (select 1 from pg_temp.sale_lines where unit_price < 0 or unit_price <> round(unit_price, 2)) then
    raise exception 'Prices must be zero or more with at most 2 decimals' using errcode = '22023';
  end if;
  if not v_can_price and exists (select 1 from pg_temp.sale_lines where unit_price <> list_price) then
    raise exception 'You are not allowed to change selling prices' using errcode = '42501';
  end if;

  update pg_temp.sale_lines set line_total = qty * unit_price where line_no is not null;
  select coalesce(sum(line_total), 0) into v_subtotal from pg_temp.sale_lines;

  -- Negotiated final amount → visible discount with a reason
  v_final := nullif(p_data ->> 'final_amount', '')::numeric;
  if v_final is not null then
    if v_final <> round(v_final, 2) or v_final < 0 then
      raise exception 'Final amount must be zero or more with at most 2 decimals' using errcode = '22023';
    end if;
    if v_final > v_subtotal then
      raise exception 'Final amount cannot be more than the bill (%)', v_subtotal using errcode = '22023';
    end if;
    v_discount := v_subtotal - v_final;
  end if;
  if v_discount > 0 then
    if not v_can_price then
      raise exception 'You are not allowed to give discounts' using errcode = '42501';
    end if;
    if v_reason = '' then
      raise exception 'Write a reason for the discount / round-off' using errcode = '22023';
    end if;
    -- Spread the discount over lines by value; remainder to the largest line.
    update pg_temp.sale_lines
       set share = case when v_subtotal = 0 then 0 else round(v_discount * line_total / v_subtotal, 2) end
     where line_no is not null;
    select coalesce(sum(share), 0) into v_alloc_sum from pg_temp.sale_lines;
    if v_alloc_sum <> v_discount then
      update pg_temp.sale_lines set share = share + (v_discount - v_alloc_sum)
       where line_no = (select line_no from pg_temp.sale_lines order by line_total desc, line_no limit 1);
    end if;
  end if;
  v_total := v_subtotal - v_discount;

  -- Payment: must be fully paid
  v_tendered := coalesce(nullif(p_data ->> 'amount_tendered', '')::numeric, v_total);
  if v_tendered < v_total then
    raise exception 'SHORTFALL: Bill is %, received %. Short by %.',
      to_char(v_total, 'FM999,999,999,990.00'), to_char(v_tendered, 'FM999,999,999,990.00'),
      to_char(v_total - v_tendered, 'FM999,999,999,990.00') using errcode = '22023';
  end if;
  if v_tendered > v_total and v_method <> 'cash' then
    raise exception 'For % enter the exact amount received (%).', v_method,
      to_char(v_total, 'FM999,999,999,990.00') using errcode = '22023';
  end if;
  v_change := v_tendered - v_total;

  -- Lock balances in a fixed order, then check stock and cost.
  perform internal.lock_balances(array(select distinct product_id from pg_temp.sale_lines order by product_id));
  for r in
    select l.product_id, l.code, sum(l.qty) as qty, b.saleable_qty
      from pg_temp.sale_lines l join public.inventory_balances b on b.product_id = l.product_id
     group by l.product_id, l.code, b.saleable_qty
  loop
    if r.saleable_qty < r.qty then
      raise exception 'INSUFFICIENT_STOCK: Only % in stock for %', r.saleable_qty, r.code using errcode = '23514';
    end if;
  end loop;

  select exists (select 1 from pg_temp.sale_lines
                  where (line_total - share) < round(qty * avg_cost, 2)) into v_below;
  if v_below then
    if not v_is_owner then
      raise exception 'This bill needs the owner''s approval. Please ask the owner.' using errcode = '42501';
    end if;
    if not coalesce((p_data ->> 'allow_below_cost')::boolean, false) then
      raise exception 'BELOW_COST: One or more items are being sold below cost. Confirm to continue.'
        using errcode = '22023';
    end if;
  end if;

  -- Create the sale
  v_invoice := 'INV-' || lpad(nextval('public.invoice_no_seq')::text, 6, '0');
  insert into public.sales (id, invoice_no, sale_type, customer_id, customer_name, customer_phone,
                            subtotal, discount_amount, discount_reason, total, payment_method,
                            amount_tendered, change_given, payment_reference, notes, idempotency_key)
  values (v_sale_id, v_invoice, v_type, v_customer_id, v_customer_name, v_customer_phone,
          v_subtotal, v_discount, v_reason, v_total, v_method, v_tendered, v_change,
          btrim(coalesce(p_data ->> 'payment_reference', '')), coalesce(p_data ->> 'notes', ''),
          p_idempotency_key);

  for r in select * from pg_temp.sale_lines order by product_id, line_no loop
    declare v_item_id uuid := gen_random_uuid();
    begin
      insert into public.sale_items (id, sale_id, line_no, product_id, product_code, product_name, quantity,
                                     list_price, unit_price, line_total, discount_share, net_total,
                                     warranty_note, warranty_days)
      values (v_item_id, v_sale_id, r.line_no, r.product_id, r.code, r.name, r.qty, r.list_price,
              r.unit_price, r.line_total, r.share, r.line_total - r.share, r.warranty_note, r.warranty_days);
      v_cost := internal.issue_stock(r.product_id, r.qty, 'sale', 'sale', v_sale_id, v_item_id, null);
      insert into private.sale_costs (sale_item_id, sale_id, product_id, quantity, unit_cost, cost_total)
      values (v_item_id, v_sale_id, r.product_id, r.qty, round(v_cost / r.qty, 6), v_cost);
    end;
  end loop;

  update public.business_settings set trading_started_at = now()
   where id = 1 and trading_started_at is null;

  perform internal.audit('sale_completed', 'sale', v_sale_id::text,
    case when v_below then 'Below cost: ' || coalesce(p_data ->> 'below_cost_reason', '') else null end,
    null,
    jsonb_build_object('invoice_no', v_invoice, 'type', v_type, 'customer', v_customer_name,
                       'subtotal', v_subtotal, 'discount', v_discount, 'discount_reason', v_reason,
                       'total', v_total, 'method', v_method));

  return jsonb_build_object('id', v_sale_id, 'invoice_no', v_invoice, 'total', v_total,
                            'change', v_change, 'already_posted', false);
end $$;

-- Owner: void a completed sale (stock returns at its original cost).
create or replace function public.owner_void_sale(p_sale_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_sale public.sales; r record;
begin
  perform internal.require_owner_unlocked();
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Write the reason for voiding this sale' using errcode = '22023';
  end if;
  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale.id is null then
    raise exception 'Sale not found' using errcode = 'P0002';
  end if;
  if v_sale.status = 'voided' then
    return;
  end if;
  perform internal.lock_balances(array(select distinct product_id from public.sale_items
                                        where sale_id = p_sale_id order by product_id));
  for r in
    select i.id, i.product_id, i.quantity, c.cost_total
      from public.sale_items i join private.sale_costs c on c.sale_item_id = i.id
     where i.sale_id = p_sale_id order by i.product_id, i.line_no
  loop
    perform internal.receive_stock(r.product_id, r.quantity, r.cost_total, 'sale_void',
                                   'sale_void', p_sale_id, r.id, btrim(p_reason));
  end loop;
  update public.sales
     set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason)
   where id = p_sale_id;
  perform internal.audit('sale_voided', 'sale', p_sale_id::text, btrim(p_reason),
    jsonb_build_object('invoice_no', v_sale.invoice_no, 'total', v_sale.total), null);
end $$;

-- Owner: cost and profit of one sale.
create or replace function public.owner_sale_profit(p_sale_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform internal.require_owner_unlocked();
  select jsonb_build_object(
           'net_sales', s.total,
           'cost', round(coalesce(sum(c.cost_total), 0), 2),
           'profit', s.total - round(coalesce(sum(c.cost_total), 0), 2),
           'discount', s.discount_amount)
    into v
    from public.sales s left join private.sale_costs c on c.sale_id = s.id
   where s.id = p_sale_id
   group by s.id, s.total, s.discount_amount;
  return v;
end $$;

-- Sales summary for a period (Karachi dates). Quantities/amounts for everyone…
create or replace function public.sales_summary(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform internal.require_active();
  select jsonb_build_object(
           'count', count(*),
           'net_sales', coalesce(sum(total), 0),
           'discounts', coalesce(sum(discount_amount), 0),
           'wholesale', coalesce(sum(total) filter (where sale_type = 'wholesale'), 0),
           'retail', coalesce(sum(total) filter (where sale_type = 'retail'), 0))
    into v
    from public.sales
   where status = 'completed'
     and (completed_at at time zone 'Asia/Karachi')::date between p_from and p_to;
  return v;
end $$;

-- …and profit only for the owner with the private area unlocked.
create or replace function public.owner_profit_summary(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform internal.require_owner_unlocked();
  with s as (
    select id, total from public.sales
     where status = 'completed'
       and (completed_at at time zone 'Asia/Karachi')::date between p_from and p_to
  ), c as (
    select round(coalesce(sum(sc.cost_total), 0), 2) as cogs
      from private.sale_costs sc where sc.sale_id in (select id from s)
  )
  select jsonb_build_object(
           'net_sales', coalesce((select sum(total) from s), 0),
           'cogs', (select cogs from c),
           'gross_profit', coalesce((select sum(total) from s), 0) - (select cogs from c))
    into v;
  return v;
end $$;

-- =====================================================================
-- Product delete (owner) — only if never used; otherwise archive.
-- Returns the photo paths so the app can remove the files.
-- =====================================================================
create or replace function public.owner_delete_product(p_product_id uuid, p_reason text)
returns text[] language plpgsql security definer set search_path = '' as $$
declare v_p public.products; v_paths text[];
begin
  perform internal.require_owner();
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Write a reason for deleting this product' using errcode = '22023';
  end if;
  select * into v_p from public.products where id = p_product_id for update;
  if v_p.id is null then
    raise exception 'Product not found' using errcode = 'P0002';
  end if;
  if exists (select 1 from private.stock_movements where product_id = p_product_id)
     or exists (select 1 from private.purchase_items where product_id = p_product_id)
     or exists (select 1 from public.sale_items where product_id = p_product_id)
     or exists (select 1 from private.opening_stock_entries where product_id = p_product_id) then
    raise exception 'PRODUCT_IN_USE: This product has stock, purchase or sale history, so it cannot be deleted (old bills must stay correct). Archive it instead.'
      using errcode = '55000';
  end if;
  select coalesce(array_agg(storage_path), '{}') into v_paths
    from public.product_images where product_id = p_product_id;
  delete from public.product_images where product_id = p_product_id;
  delete from private.inventory_valuation where product_id = p_product_id;
  delete from public.inventory_balances where product_id = p_product_id;
  delete from public.products where id = p_product_id;
  perform internal.audit('product_deleted', 'product', p_product_id::text, btrim(p_reason),
    jsonb_build_object('code', v_p.code, 'name', v_p.name, 'retail_price', v_p.retail_price,
                       'wholesale_price', v_p.wholesale_price), null);
  return v_paths;
end $$;

-- Photo add/remove + category changes are also recorded in history.
create or replace function internal.audit_product_images()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_code text;
begin
  if tg_op = 'INSERT' then
    select code into v_code from public.products where id = new.product_id;
    perform internal.audit('photo_added', 'product', new.product_id::text, null, null,
      jsonb_build_object('code', v_code));
    return new;
  else
    select code into v_code from public.products where id = old.product_id;
    -- Deleting the whole product logs separately; skip if the product is gone.
    if v_code is not null then
      perform internal.audit('photo_removed', 'product', old.product_id::text, null,
        jsonb_build_object('code', v_code), null);
    end if;
    return old;
  end if;
end $$;
create trigger product_images_audit after insert or delete on public.product_images
  for each row execute function internal.audit_product_images();

create or replace function internal.audit_categories()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform internal.audit('category_created', 'category', new.id::text, null, null, jsonb_build_object('name', new.name));
    return new;
  elsif tg_op = 'UPDATE' then
    perform internal.audit('category_updated', 'category', new.id::text, null,
      jsonb_build_object('name', old.name), jsonb_build_object('name', new.name));
    return new;
  else
    perform internal.audit('category_deleted', 'category', old.id::text, null, jsonb_build_object('name', old.name), null);
    return old;
  end if;
end $$;
create trigger categories_audit after insert or update or delete on public.categories
  for each row execute function internal.audit_categories();

-- =====================================================================
-- Activity history (owner + unlocked): who did what, when.
-- =====================================================================
create or replace function public.owner_activity_log(
  p_limit integer default 300, p_actor uuid default null, p_entity text default null)
returns table (id bigint, created_at timestamptz, actor_id uuid, actor_name text, actor_role text,
               action text, entity text, entity_id text, reason text, before_data jsonb, after_data jsonb)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select a.id, a.created_at, a.actor_id,
           coalesce(nullif(p.full_name, ''), u.email::text, 'System'),
           coalesce(p.role::text, 'system'),
           a.action, a.entity, a.entity_id, a.reason, a.before_data, a.after_data
      from private.audit_logs a
      left join public.profiles p on p.id = a.actor_id
      left join auth.users u on u.id = a.actor_id
     where (p_actor is null or a.actor_id = p_actor)
       and (p_entity is null or a.entity = p_entity)
       and a.action not in ('private_unlocked')
     order by a.created_at desc, a.id desc
     limit least(greatest(coalesce(p_limit, 300), 1), 1000);
end $$;

-- =====================================================================
-- Grants
-- =====================================================================
revoke execute on function
  public.complete_sale(jsonb, uuid), public.owner_void_sale(uuid, text), public.owner_sale_profit(uuid),
  public.sales_summary(date, date), public.owner_profit_summary(date, date),
  public.owner_delete_product(uuid, text), public.owner_activity_log(integer, uuid, text)
  from public, anon;
grant execute on function
  public.complete_sale(jsonb, uuid), public.owner_void_sale(uuid, text), public.owner_sale_profit(uuid),
  public.sales_summary(date, date), public.owner_profit_summary(date, date),
  public.owner_delete_product(uuid, text), public.owner_activity_log(integer, uuid, text)
  to authenticated;
grant usage on sequence public.invoice_no_seq to authenticated;

revoke execute on all functions in schema internal from public, anon, authenticated;
grant execute on function
  internal.is_active_user(), internal.is_owner(), internal.is_owner_unlocked(),
  internal.has_permission(text), internal.jwt_claims(), internal.current_session_id(),
  internal.current_auth_time()
  to authenticated;
