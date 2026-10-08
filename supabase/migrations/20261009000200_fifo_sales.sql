-- Preserve a cost snapshot for every portion of a sale item issued from a batch.
create table private.sale_item_costs (
  id           uuid primary key default gen_random_uuid(),
  sale_item_id uuid not null references public.sale_items(id) on delete restrict,
  batch_id     uuid not null references private.batches(id) on delete restrict,
  quantity     integer not null check (quantity > 0),
  cost_price   numeric(18,6) not null check (cost_price >= 0)
);
create index sale_item_costs_sale_item_idx on private.sale_item_costs (sale_item_id);
create index sale_item_costs_batch_idx on private.sale_item_costs (batch_id);

alter table private.sale_item_costs enable row level security;
create policy sale_item_costs_owner_select on private.sale_item_costs for select to authenticated
  using ((select internal.is_owner_unlocked()));
revoke all on private.sale_item_costs from anon, authenticated;
grant select on private.sale_item_costs to authenticated;

-- Opening stock and stock already present when FIFO is enabled also need
-- layers. Nullable purchase_id identifies these non-purchase batches.
alter table private.batches alter column purchase_id drop not null;
alter table private.batches alter column purchase_item_id drop not null;
alter table private.batches add column source_type text not null default 'purchase'
  check (source_type in ('purchase', 'opening_stock', 'migration'));
alter table private.batches add column source_id uuid;
alter table private.batches add constraint batches_source_check check (
  (source_type = 'purchase' and purchase_id is not null and purchase_item_id is not null and source_id is null)
  or (source_type = 'opening_stock' and purchase_id is null and purchase_item_id is null and source_id is not null)
  or (source_type = 'migration' and purchase_id is null and purchase_item_id is null and source_id is null)
);

-- Purchases posted before FIFO was installed already have historic sales
-- costed under the old method. Start a new FIFO layer at today's remaining
-- inventory balance rather than reassigning historical sales to batches.
update private.batches set remaining_quantity = 0 where remaining_quantity > 0;
insert into private.batches
  (product_id, purchase_id, purchase_item_id, quantity, remaining_quantity, unit_cost, posted_at, source_type)
select b.product_id, null, null, b.saleable_qty, b.saleable_qty,
       case when b.saleable_qty = 0 then 0 else round(v.carrying_value / b.saleable_qty, 6) end,
       now(), 'migration'
  from public.inventory_balances b
  join private.inventory_valuation v using (product_id)
 where b.saleable_qty > 0;

create or replace function internal.batch_opening_stock()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into private.batches
    (product_id, purchase_id, purchase_item_id, quantity, remaining_quantity,
     unit_cost, posted_at, source_type, source_id)
  values
    (new.product_id, null, null, new.quantity, new.quantity,
     new.unit_cost, new.created_at, 'opening_stock', new.id);
  return new;
end $$;

create trigger opening_stock_batch after insert on private.opening_stock_entries
  for each row execute function internal.batch_opening_stock();

-- Replace the sale inventory primitive: hold the existing product balance
-- lock, consume oldest batches first, and save each exact batch cost snapshot.
create or replace function internal.issue_stock(
  p_product_id uuid, p_qty integer, p_type public.movement_type,
  p_source_type text, p_source_id uuid, p_source_line_id uuid default null, p_reason text default null)
returns numeric language plpgsql security definer set search_path = '' as $$
declare
  v_bal public.inventory_balances;
  v_val private.inventory_valuation;
  v_batch record;
  v_take integer;
  v_remaining integer;
  v_available bigint;
  v_cost numeric(18,6) := 0;
  v_cost_after numeric(18,6);
  v_code text;
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

  select coalesce(sum(remaining_quantity), 0) into v_available
    from private.batches where product_id = p_product_id and remaining_quantity > 0;
  if v_available < p_qty then
    select code into v_code from public.products where id = p_product_id;
    raise exception 'INSUFFICIENT_STOCK: Only % FIFO-tracked units are available for %',
      v_available, v_code using errcode = '23514';
  end if;

  v_remaining := p_qty;
  for v_batch in
    select id, remaining_quantity, unit_cost
      from private.batches
     where product_id = p_product_id and remaining_quantity > 0
     order by posted_at, id
     for update
  loop
    exit when v_remaining = 0;
    v_take := least(v_remaining, v_batch.remaining_quantity);
    update private.batches
       set remaining_quantity = remaining_quantity - v_take
     where id = v_batch.id;
    insert into private.sale_item_costs (sale_item_id, batch_id, quantity, cost_price)
    values (p_source_line_id, v_batch.id, v_take, v_batch.unit_cost);
    v_cost := v_cost + v_take * v_batch.unit_cost;
    v_remaining := v_remaining - v_take;
  end loop;

  update public.inventory_balances
     set saleable_qty = saleable_qty - p_qty, version = version + 1, updated_at = now()
   where product_id = p_product_id
  returning * into v_bal;

  v_cost_after := case
    when v_bal.saleable_qty = 0 then 0
    else greatest(v_val.carrying_value - v_cost, 0)
  end;
  update private.inventory_valuation
     set carrying_value = v_cost_after,
         average_cost = case when v_bal.saleable_qty = 0 then 0 else round(v_cost_after / v_bal.saleable_qty, 6) end,
         updated_at = now()
   where product_id = p_product_id;

  insert into private.stock_movements
    (product_id, movement_type, bucket, quantity, value_change, unit_cost, qty_after, value_after,
     source_type, source_id, source_line_id, reason)
  values
    (p_product_id, p_type, 'saleable', -p_qty, -v_cost, round(v_cost / p_qty, 6),
     v_bal.saleable_qty, v_cost_after, p_source_type, p_source_id, p_source_line_id, p_reason);
  return v_cost;
end $$;
