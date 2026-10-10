-- =====================================================================
-- Corrections: fix mistakes properly, and keep a record in History.
--   * Delete a (duplicate) product together with its own purchase lines and
--     opening-stock entries. Other products are never touched. A product that
--     was SOLD cannot be deleted (old bills must stay correct) - archive it.
--   * Edit the quantity / price of a line in a POSTED purchase.
--   * Remove one line from a posted purchase, or delete the whole purchase.
--   * Edit or delete an opening-stock entry.
-- Units that were already sold can never be removed (stock cannot go below
-- what was sold). Every correction is written to the audit log with the
-- before/after values and the reason.
-- =====================================================================

-- Value-only corrections (price fixed, quantity unchanged) need a movement
-- with quantity 0 so the stock ledger still adds up.
alter table private.stock_movements drop constraint if exists stock_movements_quantity_check;
alter table private.stock_movements drop constraint if exists stock_movements_quantity_nonzero;
alter table private.stock_movements add constraint stock_movements_quantity_nonzero
  check (quantity <> 0 or movement_type in ('adjustment_in', 'adjustment_out'));

-- ---------------------------------------------------------------------
-- Core: change one stock "lot" (one purchase line / one opening entry) by
-- p_qty_delta units and p_value_delta rupees. Keeps balances, valuation,
-- lots and the movement ledger in step.
-- Older entries (from before FIFO) live in the product's "Earlier stock"
-- lot, which is used when the entry has no lot of its own.
-- ---------------------------------------------------------------------
create or replace function internal.correct_lot(
  p_product_id uuid, p_source_type text, p_source_id uuid, p_source_line_id uuid,
  p_qty_delta integer, p_value_delta numeric, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_lot private.stock_lots; v_bal public.inventory_balances; v_val private.inventory_valuation;
  v_new_left integer; v_new_in integer; v_new_value numeric(18,6); v_change numeric(18,6);
  v_qty_after integer; v_value_after numeric(18,6); v_code text;
begin
  perform internal.lock_balances(array[p_product_id]);
  select * into v_bal from public.inventory_balances where product_id = p_product_id for update;
  select * into v_val from private.inventory_valuation where product_id = p_product_id for update;
  select code into v_code from public.products where id = p_product_id;

  select * into v_lot from private.stock_lots
   where product_id = p_product_id and source_type = p_source_type and source_id = p_source_id
     and source_line_id is not distinct from p_source_line_id
   order by seq limit 1 for update;
  if v_lot.id is null then
    select * into v_lot from private.stock_lots
     where product_id = p_product_id and source_type = 'carried_forward'
     order by seq limit 1 for update;
  end if;

  if v_lot.id is null then
    if p_qty_delta > 0 then
      insert into private.stock_lots (product_id, source_type, source_id, source_line_id,
                                      qty_in, qty_left, value_left, unit_cost, received_at)
      values (p_product_id, p_source_type, p_source_id, p_source_line_id, p_qty_delta, p_qty_delta,
              greatest(p_value_delta, 0), round(greatest(p_value_delta, 0) / p_qty_delta, 6), '1970-01-01')
      returning * into v_lot;
      v_change := greatest(p_value_delta, 0);
    elsif p_qty_delta < 0 then
      raise exception 'ALREADY_SOLD: These units of % are already sold, so they cannot be removed.', v_code
        using errcode = '55000';
    else
      v_change := 0;   -- nothing left in stock to re-price
    end if;
  else
    v_new_left := v_lot.qty_left + p_qty_delta;
    v_new_in := v_lot.qty_in + p_qty_delta;
    if v_new_left < 0 then
      raise exception 'ALREADY_SOLD: Only % pcs of % from this entry are still in stock (the rest are sold). You can reduce it by at most %.',
        v_lot.qty_left, v_code, v_lot.qty_left using errcode = '55000';
    end if;
    if v_new_left = 0 then
      v_new_value := 0;
    else
      v_new_value := v_lot.value_left + p_value_delta;
      if v_new_value < 0 then
        raise exception 'ALREADY_SOLD: Most of % from this entry is already sold, so the price cannot be lowered this much.', v_code
          using errcode = '55000';
      end if;
    end if;
    v_change := v_new_value - v_lot.value_left;
    if v_new_in <= 0 then
      if exists (select 1 from private.lot_issues where lot_id = v_lot.id) then
        raise exception 'ALREADY_SOLD: Units of % from this entry are already sold.', v_code using errcode = '55000';
      end if;
      delete from private.stock_lots where id = v_lot.id;
    else
      update private.stock_lots
         set qty_in = v_new_in, qty_left = v_new_left, value_left = v_new_value,
             unit_cost = case when v_new_left > 0 then round(v_new_value / v_new_left, 6) else unit_cost end
       where id = v_lot.id;
    end if;
  end if;

  if p_qty_delta = 0 and v_change = 0 then
    return;
  end if;
  v_qty_after := v_bal.saleable_qty + p_qty_delta;
  v_value_after := greatest(v_val.carrying_value + v_change, 0);
  if v_qty_after = 0 then
    v_change := -v_val.carrying_value;
    v_value_after := 0;
  end if;
  if v_qty_after < 0 then
    raise exception 'ALREADY_SOLD: Only % pcs of % are in stock.', v_bal.saleable_qty, v_code using errcode = '55000';
  end if;

  update public.inventory_balances
     set saleable_qty = v_qty_after, version = version + 1, updated_at = now()
   where product_id = p_product_id;
  update private.inventory_valuation
     set carrying_value = v_value_after,
         average_cost = case when v_qty_after > 0 then round(v_value_after / v_qty_after, 6) else average_cost end,
         updated_at = now()
   where product_id = p_product_id;
  insert into private.stock_movements
    (product_id, movement_type, bucket, quantity, value_change, unit_cost, qty_after, value_after,
     source_type, source_id, source_line_id, reason)
  values
    (p_product_id,
     case when p_qty_delta > 0 or (p_qty_delta = 0 and v_change > 0) then 'adjustment_in'
          else 'adjustment_out' end::public.movement_type,
     'saleable', p_qty_delta, v_change,
     case when p_qty_delta <> 0 then round(abs(v_change) / abs(p_qty_delta), 6) else 0 end,
     v_qty_after, v_value_after, p_source_type || '_correction', p_source_id, p_source_line_id, p_reason);
end $$;

-- Recompute totals of a POSTED purchase after a line changed and keep its
-- payment equal to the new total (purchases are always fully paid).
create or replace function internal.refresh_posted_purchase(p_purchase_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_merch numeric(14,2); v_extra numeric(14,2); v_total numeric(14,2); v_p private.purchases;
begin
  select coalesce(sum(merchandise_value), 0), coalesce(sum(allocated_extra), 0)
    into v_merch, v_extra from private.purchase_items where purchase_id = p_purchase_id;
  v_total := v_merch + v_extra;
  update private.purchases
     set merchandise_total = v_merch, extra_costs = v_extra, total = v_total
   where id = p_purchase_id
  returning * into v_p;
  if v_total > 0 then
    insert into private.payments (direction, source_type, source_id, method, amount)
    values ('out', 'purchase', p_purchase_id, v_p.payment_method, v_total)
    on conflict (source_type, source_id) do update set amount = excluded.amount;
  else
    delete from private.payments where source_type = 'purchase' and source_id = p_purchase_id;
  end if;
end $$;

create or replace function internal.require_reason(p_reason text)
returns text language plpgsql immutable set search_path = '' as $$
begin
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Write a short reason (it is saved in History)' using errcode = '22023';
  end if;
  return btrim(p_reason);
end $$;

-- ---------------------------------------------------------------------
-- Purchase line: change quantity and/or unit price (posted purchase).
-- Transport/extra cost on the line stays the same.
-- ---------------------------------------------------------------------
create or replace function public.owner_edit_purchase_line(
  p_item_id uuid, p_quantity integer, p_unit_price numeric, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_i private.purchase_items; v_p private.purchases; v_reason text; v_code text; v_name text;
  v_merch numeric(14,2); v_landed numeric(14,2);
begin
  perform internal.require_owner_unlocked();
  v_reason := internal.require_reason(p_reason);
  select * into v_i from private.purchase_items where id = p_item_id for update;
  if v_i.id is null then
    raise exception 'Purchase line not found' using errcode = 'P0002';
  end if;
  select * into v_p from private.purchases where id = v_i.purchase_id for update;
  if v_p.status <> 'posted' then
    raise exception 'This purchase is still a draft - edit it normally' using errcode = '55000';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantity must be a positive whole number (to remove the line use Delete)' using errcode = '22023';
  end if;
  if p_unit_price is null or p_unit_price < 0 or p_unit_price <> round(p_unit_price, 2) then
    raise exception 'Unit price must be zero or more with at most 2 decimals' using errcode = '22023';
  end if;
  if p_quantity = v_i.quantity and p_unit_price = v_i.unit_price then
    return;
  end if;
  v_merch := p_quantity * p_unit_price - least(v_i.line_discount, p_quantity * p_unit_price);
  v_landed := v_merch + v_i.allocated_extra;

  perform internal.correct_lot(v_i.product_id, 'purchase', v_i.purchase_id, v_i.id,
                               p_quantity - v_i.quantity, v_landed - v_i.landed_value,
                               v_p.purchase_no || ': ' || v_reason);

  update private.purchase_items
     set quantity = p_quantity, unit_price = p_unit_price,
         line_discount = least(line_discount, p_quantity * p_unit_price),
         merchandise_value = v_merch, landed_value = v_landed,
         landed_unit_cost = round(v_landed / p_quantity, 6)
   where id = p_item_id;
  perform internal.refresh_posted_purchase(v_i.purchase_id);

  select code, name into v_code, v_name from public.products where id = v_i.product_id;
  perform internal.audit('purchase_line_edited', 'purchase', v_i.purchase_id::text, v_reason,
    jsonb_build_object('purchase_no', v_p.purchase_no, 'code', v_code, 'name', v_name,
                       'quantity', v_i.quantity, 'unit_price', v_i.unit_price, 'total', v_p.total),
    jsonb_build_object('purchase_no', v_p.purchase_no, 'code', v_code, 'name', v_name,
                       'quantity', p_quantity, 'unit_price', p_unit_price,
                       'total', (select total from private.purchases where id = v_i.purchase_id)));
end $$;

-- Remove one line from a posted purchase (only if none of it was sold).
-- Removing the last line deletes the whole purchase.
create or replace function public.owner_delete_purchase_line(p_item_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_i private.purchase_items; v_p private.purchases; v_reason text; v_code text; v_name text;
begin
  perform internal.require_owner_unlocked();
  v_reason := internal.require_reason(p_reason);
  select * into v_i from private.purchase_items where id = p_item_id for update;
  if v_i.id is null then
    raise exception 'Purchase line not found' using errcode = 'P0002';
  end if;
  select * into v_p from private.purchases where id = v_i.purchase_id for update;
  if v_p.status <> 'posted' then
    raise exception 'This purchase is still a draft - edit it normally' using errcode = '55000';
  end if;
  if (select count(*) from private.purchase_items where purchase_id = v_i.purchase_id) = 1 then
    perform public.owner_delete_purchase(v_i.purchase_id, v_reason);
    return;
  end if;

  perform internal.correct_lot(v_i.product_id, 'purchase', v_i.purchase_id, v_i.id,
                               -v_i.quantity, -v_i.landed_value, v_p.purchase_no || ': ' || v_reason);
  delete from private.purchase_items where id = p_item_id;
  perform internal.refresh_posted_purchase(v_i.purchase_id);

  select code, name into v_code, v_name from public.products where id = v_i.product_id;
  perform internal.audit('purchase_line_deleted', 'purchase', v_i.purchase_id::text, v_reason,
    jsonb_build_object('purchase_no', v_p.purchase_no, 'code', v_code, 'name', v_name,
                       'quantity', v_i.quantity, 'unit_price', v_i.unit_price, 'line_total', v_i.landed_value,
                       'total', v_p.total),
    jsonb_build_object('purchase_no', v_p.purchase_no,
                       'total', (select total from private.purchases where id = v_i.purchase_id)));
end $$;

-- Delete a whole posted purchase: its stock goes out, its payment is removed.
-- Refused if any unit from it was already sold.
create or replace function public.owner_delete_purchase(p_purchase_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_p private.purchases; v_reason text; v_i record; v_items jsonb; v_supplier text;
begin
  perform internal.require_owner_unlocked();
  v_reason := internal.require_reason(p_reason);
  select * into v_p from private.purchases where id = p_purchase_id for update;
  if v_p.id is null then
    raise exception 'Purchase not found' using errcode = 'P0002';
  end if;
  if v_p.status = 'draft' then
    delete from private.purchases where id = p_purchase_id;
    return;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('code', pr.code, 'name', pr.name, 'quantity', i.quantity,
                                               'unit_price', i.unit_price) order by i.line_no), '[]'::jsonb)
    into v_items
    from private.purchase_items i join public.products pr on pr.id = i.product_id
   where i.purchase_id = p_purchase_id;
  select name into v_supplier from private.suppliers where id = v_p.supplier_id;

  for v_i in select * from private.purchase_items where purchase_id = p_purchase_id order by product_id, line_no loop
    perform internal.correct_lot(v_i.product_id, 'purchase', p_purchase_id, v_i.id,
                                 -v_i.quantity, -v_i.landed_value, v_p.purchase_no || ' deleted: ' || v_reason);
  end loop;
  delete from private.payments where source_type = 'purchase' and source_id = p_purchase_id;
  delete from private.purchases where id = p_purchase_id;   -- lines go with it

  perform internal.audit('purchase_deleted', 'purchase', p_purchase_id::text, v_reason,
    jsonb_build_object('purchase_no', v_p.purchase_no, 'supplier', v_supplier, 'total', v_p.total,
                       'document_date', v_p.document_date, 'items', v_items), null);
end $$;

-- ---------------------------------------------------------------------
-- Opening stock: edit (quantity / unit cost) or delete one entry.
-- ---------------------------------------------------------------------
create or replace function public.owner_edit_opening_stock(
  p_entry_id uuid, p_quantity integer, p_unit_cost numeric, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_e private.opening_stock_entries; v_reason text; v_value numeric(14,2); v_code text; v_name text;
begin
  perform internal.require_owner_unlocked();
  v_reason := internal.require_reason(p_reason);
  select * into v_e from private.opening_stock_entries where id = p_entry_id for update;
  if v_e.id is null then
    raise exception 'Opening stock entry not found' using errcode = 'P0002';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantity must be a positive whole number (to remove it use Delete)' using errcode = '22023';
  end if;
  if p_unit_cost is null or p_unit_cost < 0 or p_unit_cost <> round(p_unit_cost, 2) then
    raise exception 'Unit cost must be zero or more with at most 2 decimals' using errcode = '22023';
  end if;
  if p_quantity = v_e.quantity and p_unit_cost = v_e.unit_cost then
    return;
  end if;
  v_value := round(p_quantity * p_unit_cost, 2);
  perform internal.correct_lot(v_e.product_id, 'opening_stock', v_e.id, null,
                               p_quantity - v_e.quantity, v_value - v_e.total_value,
                               'Opening stock: ' || v_reason);
  update private.opening_stock_entries
     set quantity = p_quantity, unit_cost = p_unit_cost, total_value = v_value
   where id = p_entry_id;
  select code, name into v_code, v_name from public.products where id = v_e.product_id;
  perform internal.audit('opening_stock_edited', 'opening_stock', p_entry_id::text, v_reason,
    jsonb_build_object('code', v_code, 'name', v_name, 'quantity', v_e.quantity, 'unit_cost', v_e.unit_cost),
    jsonb_build_object('code', v_code, 'name', v_name, 'quantity', p_quantity, 'unit_cost', p_unit_cost));
end $$;

create or replace function public.owner_delete_opening_stock(p_entry_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_e private.opening_stock_entries; v_reason text; v_code text; v_name text;
begin
  perform internal.require_owner_unlocked();
  v_reason := internal.require_reason(p_reason);
  select * into v_e from private.opening_stock_entries where id = p_entry_id for update;
  if v_e.id is null then
    raise exception 'Opening stock entry not found' using errcode = 'P0002';
  end if;
  perform internal.correct_lot(v_e.product_id, 'opening_stock', v_e.id, null,
                               -v_e.quantity, -v_e.total_value, 'Opening stock deleted: ' || v_reason);
  delete from private.opening_stock_entries where id = p_entry_id;
  select code, name into v_code, v_name from public.products where id = v_e.product_id;
  perform internal.audit('opening_stock_deleted', 'opening_stock', p_entry_id::text, v_reason,
    jsonb_build_object('code', v_code, 'name', v_name, 'quantity', v_e.quantity, 'unit_cost', v_e.unit_cost), null);
end $$;

-- ---------------------------------------------------------------------
-- Product delete: what WILL be removed (shown in the confirm box).
-- ---------------------------------------------------------------------
create or replace function public.owner_product_delete_preview(p_product_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner();
  return jsonb_build_object(
    'sold_lines', (select count(*) from public.sale_items where product_id = p_product_id),
    'stock', coalesce((select saleable_qty from public.inventory_balances where product_id = p_product_id), 0),
    'purchases', coalesce((select jsonb_agg(jsonb_build_object(
                    'purchase_no', coalesce(p.purchase_no, 'Draft'), 'quantity', i.quantity,
                    'other_lines', (select count(*) from private.purchase_items o
                                     where o.purchase_id = i.purchase_id and o.id <> i.id))
                    order by p.created_at)
                   from private.purchase_items i join private.purchases p on p.id = i.purchase_id
                  where i.product_id = p_product_id), '[]'::jsonb),
    'opening_entries', (select count(*) from private.opening_stock_entries where product_id = p_product_id),
    'opening_qty', coalesce((select sum(quantity) from private.opening_stock_entries where product_id = p_product_id), 0));
end $$;

-- Delete a product AND its own purchase lines / opening entries / stock.
-- Other products in the same purchases stay exactly as they are.
create or replace function public.owner_delete_product(p_product_id uuid, p_reason text)
returns text[] language plpgsql security definer set search_path = '' as $$
declare v_p public.products; v_paths text[]; v_reason text; r record; v_qty integer;
        v_lines jsonb; v_opening integer;
begin
  perform internal.require_owner();
  v_reason := btrim(coalesce(p_reason, ''));
  if v_reason = '' then
    raise exception 'Write a reason for deleting this product' using errcode = '22023';
  end if;
  select * into v_p from public.products where id = p_product_id for update;
  if v_p.id is null then
    raise exception 'Product not found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.sale_items where product_id = p_product_id) then
    raise exception 'PRODUCT_IN_USE: This product has been sold, so it cannot be deleted (old bills must stay correct). Archive it instead.'
      using errcode = '55000';
  end if;
  if (exists (select 1 from private.purchase_items where product_id = p_product_id)
      or exists (select 1 from private.opening_stock_entries where product_id = p_product_id)
      or exists (select 1 from private.stock_movements where product_id = p_product_id))
     and not internal.is_owner_unlocked() then
    raise exception 'PRIVATE_LOCKED: Unlock the Private Area to delete a product that has stock or purchases'
      using errcode = '42501';
  end if;
  select coalesce(sum(saleable_qty), 0) into v_qty from public.inventory_balances where product_id = p_product_id;

  select coalesce(jsonb_agg(jsonb_build_object('purchase_no', coalesce(p.purchase_no, 'Draft'),
                                               'quantity', i.quantity, 'unit_price', i.unit_price)), '[]'::jsonb)
    into v_lines
    from private.purchase_items i join private.purchases p on p.id = i.purchase_id
   where i.product_id = p_product_id;
  select coalesce(sum(quantity), 0) into v_opening from private.opening_stock_entries where product_id = p_product_id;

  -- Purchase lines of this product only.
  for r in select i.id, i.purchase_id, p.status, i.landed_value
             from private.purchase_items i join private.purchases p on p.id = i.purchase_id
            where i.product_id = p_product_id loop
    delete from private.purchase_items where id = r.id;
    if not exists (select 1 from private.purchase_items where purchase_id = r.purchase_id) then
      delete from private.payments where source_type = 'purchase' and source_id = r.purchase_id;
      delete from private.purchases where id = r.purchase_id;
    elsif r.status = 'posted' then
      perform internal.refresh_posted_purchase(r.purchase_id);
    else
      perform internal.allocate_purchase(r.purchase_id);
    end if;
  end loop;

  delete from private.opening_stock_entries where product_id = p_product_id;
  delete from private.lot_issues where product_id = p_product_id;
  delete from private.stock_lots where product_id = p_product_id;
  delete from private.stock_movements where product_id = p_product_id;

  select coalesce(array_agg(storage_path), '{}') into v_paths
    from public.product_images where product_id = p_product_id;
  delete from public.product_images where product_id = p_product_id;
  delete from private.inventory_valuation where product_id = p_product_id;
  delete from public.inventory_balances where product_id = p_product_id;
  delete from public.products where id = p_product_id;
  perform internal.audit('product_deleted', 'product', p_product_id::text, v_reason,
    jsonb_build_object('code', v_p.code, 'name', v_p.name, 'retail_price', v_p.retail_price,
                       'wholesale_price', v_p.wholesale_price, 'stock', v_qty,
                       'purchase_lines', v_lines, 'opening_qty', v_opening), null);
  return v_paths;
end $$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
revoke execute on function internal.correct_lot(uuid, text, uuid, uuid, integer, numeric, text),
  internal.refresh_posted_purchase(uuid), internal.require_reason(text) from public, anon, authenticated;
revoke execute on function
  public.owner_edit_purchase_line(uuid, integer, numeric, text),
  public.owner_delete_purchase_line(uuid, text),
  public.owner_delete_purchase(uuid, text),
  public.owner_edit_opening_stock(uuid, integer, numeric, text),
  public.owner_delete_opening_stock(uuid, text),
  public.owner_product_delete_preview(uuid),
  public.owner_delete_product(uuid, text)
  from public, anon;
grant execute on function
  public.owner_edit_purchase_line(uuid, integer, numeric, text),
  public.owner_delete_purchase_line(uuid, text),
  public.owner_delete_purchase(uuid, text),
  public.owner_edit_opening_stock(uuid, integer, numeric, text),
  public.owner_delete_opening_stock(uuid, text),
  public.owner_product_delete_preview(uuid),
  public.owner_delete_product(uuid, text)
  to authenticated;
