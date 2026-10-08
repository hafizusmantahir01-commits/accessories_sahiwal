-- Keep voided sale quantities attached to the FIFO layers they came from.
create or replace function public.owner_void_sale(p_sale_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_sale public.sales;
  v_item record;
  v_layer record;
  v_quantity integer;
  v_cost_total numeric(18,6);
  v_legacy_cost private.sale_costs;
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

  perform internal.lock_balances(array(
    select distinct product_id from public.sale_items
     where sale_id = p_sale_id order by product_id
  ));

  for v_item in
    select id, product_id, quantity
      from public.sale_items
     where sale_id = p_sale_id
     order by product_id, line_no
  loop
    if exists (select 1 from private.sale_item_costs where sale_item_id = v_item.id) then
      v_quantity := 0;
      v_cost_total := 0;
      for v_layer in
        select batch_id, sum(quantity)::integer as quantity,
               sum(quantity * cost_price)::numeric(18,6) as cost_total
          from private.sale_item_costs
         where sale_item_id = v_item.id
         group by batch_id
         order by batch_id
      loop
        update private.batches
           set remaining_quantity = remaining_quantity + v_layer.quantity
         where id = v_layer.batch_id
           and remaining_quantity + v_layer.quantity <= quantity;
        if not found then
          raise exception 'Cannot restore sale item % to its original batch', v_item.id
            using errcode = '23514';
        end if;
        v_quantity := v_quantity + v_layer.quantity;
        v_cost_total := v_cost_total + v_layer.cost_total;
      end loop;
      if v_quantity <> v_item.quantity then
        raise exception 'FIFO cost snapshot quantity does not match sale item %', v_item.id
          using errcode = '23514';
      end if;
    else
      select * into v_legacy_cost
        from private.sale_costs
       where sale_item_id = v_item.id;
      if v_legacy_cost.sale_item_id is null then
        raise exception 'Sale item % has no cost snapshot to restore', v_item.id
          using errcode = '23514';
      end if;
      v_quantity := v_legacy_cost.quantity;
      v_cost_total := v_legacy_cost.cost_total;
      insert into private.batches
        (product_id, quantity, remaining_quantity, unit_cost, posted_at, source_type)
      values
        (v_item.product_id, v_quantity, v_quantity, v_legacy_cost.unit_cost, now(), 'migration');
    end if;

    perform internal.receive_stock(v_item.product_id, v_quantity, v_cost_total, 'sale_void',
                                   'sale_void', p_sale_id, v_item.id, btrim(p_reason));
  end loop;

  update public.sales
     set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason)
   where id = p_sale_id;
  perform internal.audit('sale_voided', 'sale', p_sale_id::text, btrim(p_reason),
    jsonb_build_object('invoice_no', v_sale.invoice_no, 'total', v_sale.total), null);
end $$;

create or replace function internal.require_positive_purchase_sale_price()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.unit_price <= 0 then
    raise exception 'Unit price must be greater than zero' using errcode = '22023';
  end if;
  return new;
end $$;

create trigger purchase_items_positive_unit_price
  before insert or update on private.purchase_items
  for each row execute function internal.require_positive_purchase_sale_price();

create trigger sale_items_positive_unit_price
  before insert or update on public.sale_items
  for each row execute function internal.require_positive_purchase_sale_price();
