-- Purchase batches preserve the cost and posting order of each purchase line.
create table private.batches (
  id                 uuid primary key default gen_random_uuid(),
  product_id         uuid not null references public.products(id) on delete restrict,
  purchase_id        uuid not null references private.purchases(id) on delete restrict,
  purchase_item_id   uuid not null unique references private.purchase_items(id) on delete restrict,
  quantity           integer not null check (quantity > 0),
  remaining_quantity integer not null check (remaining_quantity between 0 and quantity),
  unit_cost          numeric(18,6) not null check (unit_cost >= 0),
  posted_at          timestamptz not null
);
create index batches_fifo_idx on private.batches (product_id, posted_at, id)
  where remaining_quantity > 0;

alter table private.batches enable row level security;
create policy batches_owner_select on private.batches for select to authenticated
  using ((select internal.is_owner_unlocked()));
revoke all on private.batches from anon, authenticated;
grant select on private.batches to authenticated;

-- Replacing this RPC keeps the existing purchase, stock-ledger, and payment
-- writes together with batch creation in the same PostgreSQL transaction.
create or replace function public.owner_post_purchase(
  p_purchase_id uuid, p_payment_method public.payment_method, p_amount_paid numeric,
  p_idempotency_key uuid, p_reference text default '')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_p private.purchases;
  v_item record;
  v_ids uuid[];
  v_posted_at timestamptz;
begin
  perform internal.require_owner_unlocked();
  if p_idempotency_key is null then
    raise exception 'Missing idempotency key' using errcode = '22023';
  end if;

  select * into v_p from private.purchases where id = p_purchase_id for update;
  if v_p.id is null then
    raise exception 'Purchase not found' using errcode = 'P0002';
  end if;
  if v_p.status = 'posted' then
    return jsonb_build_object('id', v_p.id, 'purchase_no', v_p.purchase_no,
                              'total', v_p.total, 'already_posted', true);
  end if;

  perform internal.allocate_purchase(p_purchase_id);
  select * into v_p from private.purchases where id = p_purchase_id;

  if not exists (select 1 from private.purchase_items where purchase_id = p_purchase_id) then
    raise exception 'Add at least one product' using errcode = '22023';
  end if;
  if p_amount_paid is null or p_amount_paid < v_p.total then
    raise exception 'SHORTFALL: Purchase total is %, paid %. Only fully-paid purchases can be posted.',
      to_char(v_p.total, 'FM999,999,999,990.00'), to_char(coalesce(p_amount_paid, 0), 'FM999,999,999,990.00')
      using errcode = '22023';
  end if;
  if p_amount_paid > v_p.total then
    raise exception 'Amount paid (%) is more than the purchase total (%). Enter the exact amount paid.',
      to_char(p_amount_paid, 'FM999,999,999,990.00'), to_char(v_p.total, 'FM999,999,999,990.00')
      using errcode = '22023';
  end if;

  select array_agg(distinct product_id order by product_id) into v_ids
    from private.purchase_items where purchase_id = p_purchase_id;
  perform internal.lock_balances(v_ids);

  v_posted_at := clock_timestamp();
  for v_item in
    select * from private.purchase_items where purchase_id = p_purchase_id order by product_id, line_no
  loop
    perform internal.receive_stock(v_item.product_id, v_item.quantity, v_item.landed_value,
                                   'purchase', 'purchase', p_purchase_id, v_item.id, null);

    insert into private.batches
      (product_id, purchase_id, purchase_item_id, quantity, remaining_quantity, unit_cost, posted_at)
    values
      (v_item.product_id, p_purchase_id, v_item.id, v_item.quantity, v_item.quantity,
       v_item.unit_price + round(v_item.allocated_extra / v_item.quantity, 6), v_posted_at);
  end loop;

  if v_p.total > 0 then
    insert into private.payments (direction, source_type, source_id, method, amount, reference)
    values ('out', 'purchase', p_purchase_id, p_payment_method, v_p.total, btrim(coalesce(p_reference, '')));
  end if;

  update private.purchases
     set status = 'posted',
         purchase_no = 'PUR-' || lpad(nextval('private.purchase_no_seq')::text, 6, '0'),
         payment_method = p_payment_method,
         idempotency_key = p_idempotency_key,
         posted_at = v_posted_at, posted_by = auth.uid()
   where id = p_purchase_id
  returning * into v_p;

  perform internal.audit('purchase_posted', 'purchase', p_purchase_id::text, null, null,
    jsonb_build_object('purchase_no', v_p.purchase_no, 'total', v_p.total, 'method', p_payment_method));

  return jsonb_build_object('id', v_p.id, 'purchase_no', v_p.purchase_no,
                            'total', v_p.total, 'already_posted', false);
end $$;
