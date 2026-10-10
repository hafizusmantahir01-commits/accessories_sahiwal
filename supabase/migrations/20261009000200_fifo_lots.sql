-- =====================================================================
-- FIFO stock by purchase ("lots").
-- Every receipt (opening stock, purchase, voided sale) becomes a lot with its
-- own quantity and cost. Sales take units from the OLDEST lot first
-- (Purchase 1 → 2 → 3 …), so the cost of each sale is the real cost of the
-- units that left, and each purchase shows how much of it is still in stock.
-- =====================================================================

create table if not exists private.stock_lots (
  id              uuid primary key default gen_random_uuid(),
  product_id      uuid not null references public.products(id) on delete restrict,
  source_type     text not null,           -- opening_stock | purchase | sale_void | carried_forward
  source_id       uuid,
  source_line_id  uuid,
  received_at     timestamptz not null default now(),
  seq             bigint generated always as identity,
  qty_in          integer not null check (qty_in > 0),
  qty_left        integer not null check (qty_left >= 0),
  value_left      numeric(18,6) not null check (value_left >= 0),
  unit_cost       numeric(18,6) not null check (unit_cost >= 0),
  check (qty_left <= qty_in)
);
create index if not exists stock_lots_fifo on private.stock_lots (product_id, received_at, seq) where qty_left > 0;
create index if not exists stock_lots_source on private.stock_lots (source_type, source_id);

-- Which lots each sale line took units from (so a void can put them back).
create table if not exists private.lot_issues (
  id              bigint generated always as identity primary key,
  lot_id          uuid not null references private.stock_lots(id) on delete restrict,
  product_id      uuid not null,
  source_type     text not null,
  source_id       uuid,
  source_line_id  uuid,
  quantity        integer not null check (quantity > 0),
  cost            numeric(18,6) not null check (cost >= 0),
  created_at      timestamptz not null default now()
);
create index if not exists lot_issues_line on private.lot_issues (source_type, source_line_id);

alter table private.stock_lots enable row level security;
alter table private.lot_issues enable row level security;
revoke all on private.stock_lots, private.lot_issues from anon, authenticated;

-- Existing stock (before FIFO) becomes one lot per product at its current value.
insert into private.stock_lots (product_id, source_type, qty_in, qty_left, value_left, unit_cost, received_at)
select b.product_id, 'carried_forward', b.saleable_qty, b.saleable_qty, v.carrying_value,
       round(v.carrying_value / b.saleable_qty, 6), '1970-01-01'::timestamptz
  from public.inventory_balances b join private.inventory_valuation v using (product_id)
 where b.saleable_qty > 0
   and not exists (select 1 from private.stock_lots l where l.product_id = b.product_id);

-- ---------------------------------------------------------------------
-- Receive: same totals as before + a new lot (a voided sale puts the
-- units back into the exact lots they came from).
-- ---------------------------------------------------------------------
create or replace function internal.receive_stock(
  p_product_id uuid, p_qty integer, p_value numeric, p_type public.movement_type,
  p_source_type text, p_source_id uuid, p_source_line_id uuid default null, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_bal public.inventory_balances; v_val private.inventory_valuation;
  v_new_qty integer; v_new_value numeric(18,6); v_avg numeric(18,6); r record;
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

  if p_type = 'sale_void' and p_source_line_id is not null
     and exists (select 1 from private.lot_issues where source_type = 'sale' and source_line_id = p_source_line_id) then
    for r in select * from private.lot_issues
              where source_type = 'sale' and source_line_id = p_source_line_id order by id loop
      update private.stock_lots
         set qty_left = qty_left + r.quantity, value_left = value_left + r.cost
       where id = r.lot_id;
    end loop;
    delete from private.lot_issues where source_type = 'sale' and source_line_id = p_source_line_id;
  else
    insert into private.stock_lots (product_id, source_type, source_id, source_line_id,
                                    qty_in, qty_left, value_left, unit_cost)
    values (p_product_id, p_source_type, p_source_id, p_source_line_id,
            p_qty, p_qty, p_value, round(p_value / p_qty, 6));
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Issue: take units from the oldest lots first; cost = cost of those units.
-- ---------------------------------------------------------------------
create or replace function internal.issue_stock(
  p_product_id uuid, p_qty integer, p_type public.movement_type,
  p_source_type text, p_source_id uuid, p_source_line_id uuid default null, p_reason text default null)
returns numeric language plpgsql security definer set search_path = '' as $$
declare
  v_bal public.inventory_balances; v_val private.inventory_valuation;
  v_cost numeric(18,6) := 0; v_code text; v_need integer := p_qty; v_take integer; v_part numeric(18,6);
  v_left_qty integer; lot private.stock_lots;
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

  for lot in
    select * from private.stock_lots
     where product_id = p_product_id and qty_left > 0
     order by received_at, seq
     for update
  loop
    exit when v_need = 0;
    v_take := least(v_need, lot.qty_left);
    v_part := case when v_take = lot.qty_left then lot.value_left
                   else round(v_take * lot.value_left / lot.qty_left, 6) end;
    update private.stock_lots set qty_left = qty_left - v_take, value_left = value_left - v_part where id = lot.id;
    insert into private.lot_issues (lot_id, product_id, source_type, source_id, source_line_id, quantity, cost)
    values (lot.id, p_product_id, p_source_type, p_source_id, p_source_line_id, v_take, v_part);
    v_cost := v_cost + v_part;
    v_need := v_need - v_take;
  end loop;

  if v_need > 0 then
    -- Safety net (lots out of step with totals): price the rest at average cost.
    v_cost := v_cost + least(round(v_need * v_val.average_cost, 6), greatest(v_val.carrying_value - v_cost, 0));
  end if;
  if p_qty = v_bal.saleable_qty then
    v_cost := v_val.carrying_value;           -- last units take whatever value remains
  end if;
  v_cost := least(v_cost, v_val.carrying_value);
  v_left_qty := v_bal.saleable_qty - p_qty;

  update public.inventory_balances
     set saleable_qty = v_left_qty, version = version + 1, updated_at = now()
   where product_id = p_product_id;
  update private.inventory_valuation
     set carrying_value = carrying_value - v_cost,
         average_cost = case when v_left_qty > 0 then round((carrying_value - v_cost) / v_left_qty, 6) else average_cost end,
         updated_at = now()
   where product_id = p_product_id;
  insert into private.stock_movements
    (product_id, movement_type, bucket, quantity, value_change, unit_cost, qty_after, value_after,
     source_type, source_id, source_line_id, reason)
  values
    (p_product_id, p_type, 'saleable', -p_qty, -v_cost, round(v_cost / p_qty, 6),
     v_left_qty, v_val.carrying_value - v_cost,
     p_source_type, p_source_id, p_source_line_id, p_reason);
  return v_cost;
end $$;

-- ---------------------------------------------------------------------
-- Owner views
-- ---------------------------------------------------------------------
create or replace function internal.lot_source_label(p_type text, p_source uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case p_type
    when 'purchase' then coalesce((select purchase_no from private.purchases where id = p_source), 'Purchase')
    when 'opening_stock' then 'Opening stock'
    when 'sale_void' then 'Returned (voided sale)'
    when 'carried_forward' then 'Earlier stock'
    else p_type end
$$;

-- Stock of one product split by purchase (oldest first = sold first).
create or replace function public.owner_product_lots(p_product_id uuid)
returns table (lot_id uuid, source_label text, received_at timestamptz, qty_in integer, qty_left integer,
               unit_cost numeric, value_left numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select l.id, internal.lot_source_label(l.source_type, l.source_id), l.received_at, l.qty_in, l.qty_left,
           round(l.unit_cost, 2), round(l.value_left, 2)
      from private.stock_lots l
     where l.product_id = p_product_id and l.qty_left > 0
     order by l.received_at, l.seq;
end $$;

-- Each line of one purchase: received, sold, still in stock.
create or replace function public.owner_purchase_stock(p_purchase_id uuid)
returns table (purchase_item_id uuid, product_id uuid, product_code text, product_name text,
               qty_in integer, qty_left integer, qty_sold integer, unit_cost numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select l.source_line_id, l.product_id, p.code, p.name, sum(l.qty_in)::int, sum(l.qty_left)::int,
           (sum(l.qty_in) - sum(l.qty_left))::int, round(max(l.unit_cost), 2)
      from private.stock_lots l join public.products p on p.id = l.product_id
     where l.source_type = 'purchase' and l.source_id = p_purchase_id
     group by l.source_line_id, l.product_id, p.code, p.name
     order by p.name;
end $$;

-- Remaining units per posted purchase (for the purchases list).
create or replace function public.owner_purchase_remaining()
returns table (purchase_id uuid, qty_in integer, qty_left integer)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select l.source_id, sum(l.qty_in)::int, sum(l.qty_left)::int
      from private.stock_lots l
     where l.source_type = 'purchase'
     group by l.source_id;
end $$;

revoke execute on function internal.lot_source_label(text, uuid) from public, anon, authenticated;
revoke execute on function public.owner_product_lots(uuid), public.owner_purchase_stock(uuid),
  public.owner_purchase_remaining() from public, anon;
grant execute on function public.owner_product_lots(uuid), public.owner_purchase_stock(uuid),
  public.owner_purchase_remaining() to authenticated;
