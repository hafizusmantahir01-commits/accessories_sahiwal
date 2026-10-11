-- =====================================================================
-- 1. Stock adjustment   (broken / lost / count difference / found extra)
-- 2. Customer returns   (part of a bill comes back; good → stock,
--                         damaged → "Damaged", not sellable)
-- 3. Expenses           (rent, electricity, salary … → real net profit)
-- 4. Reports            (sales − returns, profit − expenses − stock loss)
-- 5. Shopkeeper ledger  (bills, amount, products, rates, profit per shop)
-- Every change is written to History (audit log) with who / when / why.
-- =====================================================================

-- =====================================================================
-- 1. STOCK ADJUSTMENT
-- =====================================================================
create table if not exists private.stock_adjustments (
  id            uuid primary key default gen_random_uuid(),
  product_id    uuid not null references public.products(id) on delete cascade,
  qty_change    integer not null check (qty_change <> 0),
  kind          text not null check (kind in ('damaged', 'lost', 'count', 'other')),
  note          text not null default '' check (char_length(note) <= 300),
  value_change  numeric(14,2) not null,
  created_by    uuid references auth.users(id) on delete set null default auth.uid(),
  created_at    timestamptz not null default now()
);
create index if not exists stock_adjustments_created_idx on private.stock_adjustments (created_at desc);
create index if not exists stock_adjustments_product_idx on private.stock_adjustments (product_id, created_at desc);
alter table private.stock_adjustments enable row level security;
revoke all on private.stock_adjustments from anon, authenticated;

-- p_qty_change: negative = remove (broken, lost, fewer on shelf),
--               positive = add (found extra on counting).
-- Removed units leave at their real FIFO cost (= stock loss).
-- Added units come in at p_unit_cost, or the current average cost.
create or replace function public.owner_adjust_stock(
  p_product_id uuid, p_qty_change integer, p_kind text, p_note text default '', p_unit_cost numeric default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid(); v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_note text := btrim(coalesce(p_note, '')); v_label text; v_reason text;
  v_code text; v_name text; v_value numeric(18,6); v_unit numeric(18,6); v_after integer;
begin
  perform internal.require_owner_unlocked();
  if p_qty_change is null or p_qty_change = 0 then
    raise exception 'Enter how many pieces to add or remove' using errcode = '22023';
  end if;
  if abs(p_qty_change) > 1000000 then
    raise exception 'Quantity is too large' using errcode = '22023';
  end if;
  if v_kind not in ('damaged', 'lost', 'count', 'other') then
    raise exception 'Choose what happened (damaged, lost, count difference or other)' using errcode = '22023';
  end if;
  if v_kind = 'other' and v_note = '' then
    raise exception 'Write what happened' using errcode = '22023';
  end if;
  if char_length(v_note) > 300 then
    raise exception 'Note is too long (max 300 characters)' using errcode = '22023';
  end if;
  select code, name into v_code, v_name from public.products where id = p_product_id;
  if v_code is null then
    raise exception 'Product not found' using errcode = 'P0002';
  end if;
  v_label := case v_kind when 'damaged' then 'Damaged / broken' when 'lost' then 'Lost / missing'
                         when 'count' then 'Count difference' else 'Other' end;
  v_reason := v_label || case when v_note <> '' then ': ' || v_note else '' end;

  perform internal.lock_balances(array[p_product_id]);
  if p_qty_change < 0 then
    v_value := -internal.issue_stock(p_product_id, -p_qty_change,
                 case when v_kind = 'damaged' then 'damage' else 'adjustment_out' end::public.movement_type,
                 'adjustment', v_id, null, v_reason);
  else
    if p_unit_cost is not null then
      if p_unit_cost < 0 or p_unit_cost <> round(p_unit_cost, 2) then
        raise exception 'Unit cost must be zero or more with at most 2 decimals' using errcode = '22023';
      end if;
      v_unit := p_unit_cost;
    else
      select coalesce(nullif(v.average_cost, 0),
                      (select l.unit_cost from private.stock_lots l where l.product_id = p_product_id
                        order by l.received_at desc, l.seq desc limit 1), 0)
        into v_unit from private.inventory_valuation v where v.product_id = p_product_id;
    end if;
    v_value := round(p_qty_change * coalesce(v_unit, 0), 2);
    perform internal.receive_stock(p_product_id, p_qty_change, v_value, 'adjustment_in',
                                   'adjustment', v_id, null, v_reason);
  end if;

  insert into private.stock_adjustments (id, product_id, qty_change, kind, note, value_change)
  values (v_id, p_product_id, p_qty_change, v_kind, v_note, round(v_value, 2));
  select saleable_qty into v_after from public.inventory_balances where product_id = p_product_id;
  perform internal.audit('stock_adjusted', 'product', p_product_id::text, v_reason, null,
    jsonb_build_object('code', v_code, 'name', v_name, 'qty_change', p_qty_change, 'kind', v_kind,
                       'value_change', round(v_value, 2), 'qty_after', v_after));
  return jsonb_build_object('id', v_id, 'qty_change', p_qty_change, 'value_change', round(v_value, 2),
                            'qty_after', v_after);
end $$;

-- Recent adjustments (owner).
create or replace function public.owner_list_adjustments(p_product_id uuid default null, p_limit integer default 100)
returns table (id uuid, product_id uuid, code text, name text, qty_change integer, kind text, note text,
               value_change numeric, created_by_name text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select a.id, a.product_id, p.code, p.name, a.qty_change, a.kind, a.note, a.value_change,
           coalesce(nullif(pr.full_name, ''), 'User'), a.created_at
      from private.stock_adjustments a
      join public.products p on p.id = a.product_id
      left join public.profiles pr on pr.id = a.created_by
     where p_product_id is null or a.product_id = p_product_id
     order by a.created_at desc
     limit least(greatest(coalesce(p_limit, 100), 1), 500);
end $$;

-- =====================================================================
-- 2. CUSTOMER RETURNS
-- =====================================================================
create sequence if not exists public.return_no_seq start 1;

create table if not exists public.sale_returns (
  id               uuid primary key default gen_random_uuid(),
  return_no        text not null unique,
  sale_id          uuid not null references public.sales(id) on delete restrict,
  customer_id      uuid references public.customers(id) on delete set null,
  customer_name    text not null default '',
  refund_amount    numeric(14,2) not null default 0 check (refund_amount >= 0),
  refund_method    public.payment_method not null default 'cash',
  reason           text not null check (char_length(btrim(reason)) between 1 and 300),
  idempotency_key  uuid not null unique,
  created_by       uuid references auth.users(id) on delete set null default auth.uid(),
  created_at       timestamptz not null default now()
);
create index if not exists sale_returns_sale_idx on public.sale_returns (sale_id);
create index if not exists sale_returns_created_idx on public.sale_returns (created_at desc);
create index if not exists sale_returns_customer_idx on public.sale_returns (customer_id);

create table if not exists public.sale_return_items (
  id             uuid primary key default gen_random_uuid(),
  return_id      uuid not null references public.sale_returns(id) on delete restrict,
  sale_item_id   uuid not null references public.sale_items(id) on delete restrict,
  product_id     uuid not null references public.products(id) on delete restrict,
  product_code   text not null,
  product_name   text not null,
  quantity       integer not null check (quantity > 0),
  refund_amount  numeric(14,2) not null check (refund_amount >= 0),
  condition      text not null check (condition in ('good', 'damaged'))
);
create index if not exists sale_return_items_return_idx on public.sale_return_items (return_id);
create index if not exists sale_return_items_line_idx on public.sale_return_items (sale_item_id);

-- Owner-only: cost of the returned units (taken back out of COGS).
create table if not exists private.sale_return_costs (
  return_item_id  uuid primary key references public.sale_return_items(id) on delete restrict,
  return_id       uuid not null references public.sale_returns(id) on delete restrict,
  product_id      uuid not null references public.products(id) on delete restrict,
  condition       text not null,
  cost_total      numeric(18,6) not null check (cost_total >= 0)
);
create index if not exists sale_return_costs_return_idx on private.sale_return_costs (return_id);

alter table public.sale_returns enable row level security;
alter table public.sale_return_items enable row level security;
alter table private.sale_return_costs enable row level security;
drop policy if exists sale_returns_select on public.sale_returns;
create policy sale_returns_select on public.sale_returns for select to authenticated
  using ((select internal.is_active_user()));
drop policy if exists sale_return_items_select on public.sale_return_items;
create policy sale_return_items_select on public.sale_return_items for select to authenticated
  using ((select internal.is_active_user()));
drop policy if exists sale_return_costs_select on private.sale_return_costs;
create policy sale_return_costs_select on private.sale_return_costs for select to authenticated
  using ((select internal.is_owner_unlocked()));
revoke all on public.sale_returns, public.sale_return_items from anon, authenticated;
revoke all on private.sale_return_costs from anon, authenticated;
grant select on public.sale_returns, public.sale_return_items to authenticated;
grant select on private.sale_return_costs to authenticated;

-- Friendly names for the new stock "lots".
create or replace function internal.lot_source_label(p_type text, p_source uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case p_type
    when 'purchase' then coalesce((select purchase_no from private.purchases where id = p_source), 'Purchase')
    when 'opening_stock' then 'Opening stock'
    when 'sale_void' then 'Returned (voided sale)'
    when 'sale_return' then coalesce('Customer return ' || (select return_no from public.sale_returns where id = p_source),
                                     'Customer return')
    when 'adjustment' then 'Stock adjustment'
    when 'carried_forward' then 'Earlier stock'
    else p_type end
$$;

-- p_items: [{ sale_item_id, quantity, condition: 'good' | 'damaged' }]
-- Refund = what the customer really paid for those pieces (after the bill
-- discount share). Good pieces go back into stock at their sale cost;
-- damaged pieces go to "Damaged" and their cost counts as stock loss.
create or replace function public.owner_create_sale_return(
  p_sale_id uuid, p_items jsonb, p_reason text, p_refund_method public.payment_method,
  p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_sale public.sales; v_existing public.sale_returns; v_id uuid := gen_random_uuid(); v_no text;
  v_item jsonb; v_si public.sale_items; v_qty integer; v_cond text; v_returned integer;
  v_prev_refund numeric(14,2); v_prev_cost numeric(18,6); v_line_cost numeric(18,6);
  v_refund numeric(14,2); v_cost numeric(18,6); v_total numeric(14,2) := 0; v_ri uuid;
  v_lines jsonb := '[]'::jsonb; v_ns integer;
begin
  perform internal.require_owner();
  if p_idempotency_key is null then
    raise exception 'Missing idempotency key' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text, 0));
  select * into v_existing from public.sale_returns where idempotency_key = p_idempotency_key;
  if v_existing.id is not null then
    return jsonb_build_object('id', v_existing.id, 'return_no', v_existing.return_no,
                              'refund', v_existing.refund_amount, 'already_posted', true);
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Write the reason for the return' using errcode = '22023';
  end if;
  select * into v_sale from public.sales where id = p_sale_id for update;
  if v_sale.id is null then
    raise exception 'Sale not found' using errcode = 'P0002';
  end if;
  if v_sale.status <> 'completed' then
    raise exception 'This sale is voided, nothing can be returned' using errcode = '55000';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Choose at least one item to return' using errcode = '22023';
  end if;

  perform internal.lock_balances(array(select distinct product_id from public.sale_items
                                        where sale_id = p_sale_id order by product_id));
  v_no := 'RET-' || lpad(nextval('public.return_no_seq')::text, 6, '0');
  insert into public.sale_returns (id, return_no, sale_id, customer_id, customer_name, refund_amount,
                                   refund_method, reason, idempotency_key)
  values (v_id, v_no, p_sale_id, v_sale.customer_id, v_sale.customer_name, 0,
          coalesce(p_refund_method, 'cash'), btrim(p_reason), p_idempotency_key);

  for v_item in select * from jsonb_array_elements(p_items) loop
    if coalesce(v_item ->> 'quantity', '') !~ '^[0-9]+$' or (v_item ->> 'quantity')::integer <= 0 then
      raise exception 'Return quantity must be a whole number of at least 1' using errcode = '22023';
    end if;
    v_qty := (v_item ->> 'quantity')::integer;
    v_cond := coalesce(nullif(v_item ->> 'condition', ''), 'good');
    if v_cond not in ('good', 'damaged') then
      raise exception 'Condition must be good or damaged' using errcode = '22023';
    end if;
    select * into v_si from public.sale_items
     where id = nullif(v_item ->> 'sale_item_id', '')::uuid and sale_id = p_sale_id;
    if v_si.id is null then
      raise exception 'This item is not in the bill' using errcode = 'P0002';
    end if;
    select coalesce(sum(quantity), 0), coalesce(sum(refund_amount), 0) into v_returned, v_prev_refund
      from public.sale_return_items where sale_item_id = v_si.id;
    if v_returned + v_qty > v_si.quantity then
      raise exception 'ALREADY_RETURNED: Only % pcs of % can still be returned from this bill.',
        v_si.quantity - v_returned, v_si.product_name using errcode = '23514';
    end if;
    select coalesce(sum(rc.cost_total), 0) into v_prev_cost
      from private.sale_return_costs rc join public.sale_return_items ri on ri.id = rc.return_item_id
     where ri.sale_item_id = v_si.id;
    select cost_total into v_line_cost from private.sale_costs where sale_item_id = v_si.id;
    if v_returned + v_qty = v_si.quantity then           -- last pieces: no rounding left over
      v_refund := v_si.net_total - v_prev_refund;
      v_cost := greatest(coalesce(v_line_cost, 0) - v_prev_cost, 0);
    else
      v_refund := round(v_si.net_total * v_qty / v_si.quantity, 2);
      v_cost := round(coalesce(v_line_cost, 0) * v_qty / v_si.quantity, 6);
    end if;

    v_ri := gen_random_uuid();
    insert into public.sale_return_items (id, return_id, sale_item_id, product_id, product_code, product_name,
                                          quantity, refund_amount, condition)
    values (v_ri, v_id, v_si.id, v_si.product_id, v_si.product_code, v_si.product_name, v_qty, v_refund, v_cond);
    insert into private.sale_return_costs (return_item_id, return_id, product_id, condition, cost_total)
    values (v_ri, v_id, v_si.product_id, v_cond, v_cost);

    if v_cond = 'good' then
      perform internal.receive_stock(v_si.product_id, v_qty, v_cost, 'sale_return', 'sale_return',
                                     v_id, v_ri, v_no || ': ' || btrim(p_reason));
    else
      update public.inventory_balances
         set non_saleable_qty = non_saleable_qty + v_qty, version = version + 1, updated_at = now()
       where product_id = v_si.product_id
      returning non_saleable_qty into v_ns;
      insert into private.stock_movements
        (product_id, movement_type, bucket, quantity, value_change, unit_cost, qty_after, value_after,
         source_type, source_id, source_line_id, reason)
      values
        (v_si.product_id, 'sale_return', 'non_saleable', v_qty, 0, round(v_cost / v_qty, 6), v_ns,
         (select carrying_value from private.inventory_valuation where product_id = v_si.product_id),
         'sale_return', v_id, v_ri, v_no || ' (damaged): ' || btrim(p_reason));
    end if;
    v_total := v_total + v_refund;
    v_lines := v_lines || jsonb_build_object('code', v_si.product_code, 'name', v_si.product_name,
                                             'quantity', v_qty, 'refund', v_refund, 'condition', v_cond);
  end loop;

  update public.sale_returns set refund_amount = v_total where id = v_id;
  if v_total > 0 then
    insert into private.payments (direction, source_type, source_id, method, amount)
    values ('out', 'sale_refund', v_id, coalesce(p_refund_method, 'cash'), v_total);
  end if;
  perform internal.audit('sale_returned', 'sale', p_sale_id::text, btrim(p_reason), null,
    jsonb_build_object('invoice_no', v_sale.invoice_no, 'return_no', v_no, 'customer', v_sale.customer_name,
                       'refund', v_total, 'method', coalesce(p_refund_method, 'cash'), 'items', v_lines));
  return jsonb_build_object('id', v_id, 'return_no', v_no, 'refund', v_total, 'already_posted', false);
end $$;

-- A bill that already has a return cannot be voided as a whole
-- (return the remaining items instead) - keeps stock and money exact.
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
  if exists (select 1 from public.sale_returns where sale_id = p_sale_id) then
    raise exception 'HAS_RETURNS: Some items of this bill were already returned. Use "Return items" for the rest instead of voiding.'
      using errcode = '55000';
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

-- =====================================================================
-- 3. EXPENSES
-- =====================================================================
create table if not exists private.expenses (
  id            uuid primary key default gen_random_uuid(),
  expense_date  date not null default (now() at time zone 'Asia/Karachi')::date,
  category      text not null check (category in ('rent', 'electricity', 'salary', 'transport', 'food',
                                                  'repair', 'other')),
  amount        numeric(14,2) not null check (amount > 0),
  note          text not null default '' check (char_length(note) <= 300),
  created_by    uuid references auth.users(id) on delete set null default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists expenses_date_idx on private.expenses (expense_date desc);
alter table private.expenses enable row level security;
revoke all on private.expenses from anon, authenticated;

-- Add (p_id null) or edit (p_id + reason) an expense.
create or replace function public.owner_save_expense(
  p_id uuid, p_date date, p_category text, p_amount numeric, p_note text default '', p_reason text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_old private.expenses; v_new private.expenses; v_cat text := lower(btrim(coalesce(p_category, '')));
begin
  perform internal.require_owner_unlocked();
  if v_cat not in ('rent', 'electricity', 'salary', 'transport', 'food', 'repair', 'other') then
    raise exception 'Choose a category' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    raise exception 'Amount must be more than 0 with at most 2 decimals' using errcode = '22023';
  end if;
  if p_date is null or p_date > (now() at time zone 'Asia/Karachi')::date then
    raise exception 'Expense date cannot be in the future' using errcode = '22023';
  end if;
  if v_cat = 'other' and btrim(coalesce(p_note, '')) = '' then
    raise exception 'Write what the expense was for' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_note, ''))) > 300 then
    raise exception 'Note is too long (max 300 characters)' using errcode = '22023';
  end if;
  if p_id is null then
    insert into private.expenses (expense_date, category, amount, note)
    values (p_date, v_cat, p_amount, btrim(coalesce(p_note, '')))
    returning * into v_new;
    perform internal.audit('expense_added', 'expense', v_new.id::text, null, null,
      jsonb_build_object('date', v_new.expense_date, 'category', v_cat, 'amount', v_new.amount, 'note', v_new.note));
  else
    if btrim(coalesce(p_reason, '')) = '' then
      raise exception 'Write a short reason (it is saved in History)' using errcode = '22023';
    end if;
    select * into v_old from private.expenses where id = p_id for update;
    if v_old.id is null then
      raise exception 'Expense not found' using errcode = 'P0002';
    end if;
    update private.expenses
       set expense_date = p_date, category = v_cat, amount = p_amount,
           note = btrim(coalesce(p_note, '')), updated_at = now()
     where id = p_id
    returning * into v_new;
    perform internal.audit('expense_edited', 'expense', p_id::text, btrim(p_reason),
      jsonb_build_object('date', v_old.expense_date, 'category', v_old.category, 'amount', v_old.amount, 'note', v_old.note),
      jsonb_build_object('date', v_new.expense_date, 'category', v_new.category, 'amount', v_new.amount, 'note', v_new.note));
  end if;
  return v_new.id;
end $$;

create or replace function public.owner_delete_expense(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_old private.expenses;
begin
  perform internal.require_owner_unlocked();
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Write a short reason (it is saved in History)' using errcode = '22023';
  end if;
  select * into v_old from private.expenses where id = p_id for update;
  if v_old.id is null then
    raise exception 'Expense not found' using errcode = 'P0002';
  end if;
  delete from private.expenses where id = p_id;
  perform internal.audit('expense_deleted', 'expense', p_id::text, btrim(p_reason),
    jsonb_build_object('date', v_old.expense_date, 'category', v_old.category, 'amount', v_old.amount, 'note', v_old.note),
    null);
end $$;

drop function if exists public.owner_list_expenses(date, date);
create function public.owner_list_expenses(p_from date, p_to date)
returns table (id uuid, expense_date date, category text, amount numeric, note text,
               created_by_name text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select e.id, e.expense_date, e.category, e.amount, e.note,
           coalesce(nullif(pr.full_name, ''), 'User'), e.created_at
      from private.expenses e left join public.profiles pr on pr.id = e.created_by
     where e.expense_date between p_from and p_to
     order by e.expense_date desc, e.created_at desc
     limit 2000;
end $$;

-- =====================================================================
-- 4. REPORTS (sales − returns; profit − stock loss − expenses)
-- =====================================================================
create or replace function internal.kdate(p_ts timestamptz)
returns date language sql immutable set search_path = '' as $$
  select (p_ts at time zone 'Asia/Karachi')::date
$$;

create or replace function public.sales_summary(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform internal.require_active();
  with s as (
    select id, total, discount_amount, sale_type from public.sales
     where status = 'completed' and internal.kdate(completed_at) between p_from and p_to
  ), r as (
    select id, refund_amount from public.sale_returns where internal.kdate(created_at) between p_from and p_to
  )
  select jsonb_build_object(
           'count', (select count(*) from s),
           'pieces', coalesce((select sum(i.quantity) from public.sale_items i where i.sale_id in (select id from s)), 0)
                     - coalesce((select sum(ri.quantity) from public.sale_return_items ri where ri.return_id in (select id from r)), 0),
           'gross_sales', coalesce((select sum(total) from s), 0),
           'returns', coalesce((select sum(refund_amount) from r), 0),
           'returns_count', (select count(*) from r),
           'net_sales', coalesce((select sum(total) from s), 0) - coalesce((select sum(refund_amount) from r), 0),
           'discounts', coalesce((select sum(discount_amount) from s), 0),
           'wholesale', coalesce((select sum(total) from s where sale_type = 'wholesale'), 0),
           'retail', coalesce((select sum(total) from s where sale_type = 'retail'), 0))
    into v;
  return v;
end $$;

create or replace function public.owner_profit_summary(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_sales numeric; v_refunds numeric; v_cogs numeric; v_ret_cost numeric; v_damaged numeric;
  v_adjust numeric; v_exp numeric; v_net numeric; v_gross numeric; v_loss numeric;
begin
  perform internal.require_owner_unlocked();
  select coalesce(sum(s.total), 0) into v_sales from public.sales s
   where s.status = 'completed' and internal.kdate(s.completed_at) between p_from and p_to;
  select round(coalesce(sum(c.cost_total), 0), 2) into v_cogs
    from private.sale_costs c join public.sales s on s.id = c.sale_id
   where s.status = 'completed' and internal.kdate(s.completed_at) between p_from and p_to;
  select coalesce(sum(r.refund_amount), 0) into v_refunds from public.sale_returns r
   where internal.kdate(r.created_at) between p_from and p_to;
  select round(coalesce(sum(rc.cost_total), 0), 2),
         round(coalesce(sum(rc.cost_total) filter (where rc.condition = 'damaged'), 0), 2)
    into v_ret_cost, v_damaged
    from private.sale_return_costs rc join public.sale_returns r on r.id = rc.return_id
   where internal.kdate(r.created_at) between p_from and p_to;
  select coalesce(sum(a.value_change), 0) into v_adjust from private.stock_adjustments a
   where internal.kdate(a.created_at) between p_from and p_to;
  select coalesce(sum(e.amount), 0) into v_exp from private.expenses e
   where e.expense_date between p_from and p_to;

  v_net := v_sales - v_refunds;
  v_gross := v_net - (v_cogs - v_ret_cost);
  v_loss := v_damaged - v_adjust;          -- adjustments: negative value = loss, positive = gain
  return jsonb_build_object(
    'sales', v_sales, 'returns', v_refunds, 'net_sales', v_net,
    'cogs', v_cogs - v_ret_cost, 'gross_profit', v_gross,
    'stock_loss', v_loss, 'expenses', v_exp,
    'net_profit', v_gross - v_loss - v_exp);
end $$;

drop function if exists public.owner_profit_by_month(date, date);
create function public.owner_profit_by_month(p_from date, p_to date)
returns table (month date, bills bigint, pieces bigint, net_sales numeric, cogs numeric, profit numeric,
               returns numeric, stock_loss numeric, expenses numeric, net_profit numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    with ev as (
      -- sales
      select date_trunc('month', internal.kdate(s.completed_at))::date as m, 1 as bills,
             (select coalesce(sum(i.quantity), 0) from public.sale_items i where i.sale_id = s.id) as pcs,
             s.total as sales, 0::numeric as refunds,
             (select coalesce(sum(c.cost_total), 0) from private.sale_costs c where c.sale_id = s.id) as cost,
             0::numeric as loss, 0::numeric as exp
        from public.sales s
       where s.status = 'completed' and internal.kdate(s.completed_at) between p_from and p_to
      union all
      -- returns
      select date_trunc('month', internal.kdate(r.created_at))::date, 0,
             -(select coalesce(sum(ri.quantity), 0) from public.sale_return_items ri where ri.return_id = r.id),
             0, r.refund_amount,
             -(select coalesce(sum(rc.cost_total), 0) from private.sale_return_costs rc where rc.return_id = r.id),
             (select coalesce(sum(rc.cost_total), 0) from private.sale_return_costs rc
               where rc.return_id = r.id and rc.condition = 'damaged'), 0
        from public.sale_returns r
       where internal.kdate(r.created_at) between p_from and p_to
      union all
      -- stock adjustments
      select date_trunc('month', internal.kdate(a.created_at))::date, 0, 0, 0, 0, 0, -a.value_change, 0
        from private.stock_adjustments a
       where internal.kdate(a.created_at) between p_from and p_to
      union all
      -- expenses
      select date_trunc('month', e.expense_date)::date, 0, 0, 0, 0, 0, 0, e.amount
        from private.expenses e
       where e.expense_date between p_from and p_to
    )
    select ev.m, sum(ev.bills)::bigint, sum(ev.pcs)::bigint,
           sum(ev.sales) - sum(ev.refunds),
           round(sum(ev.cost), 2),
           sum(ev.sales) - sum(ev.refunds) - round(sum(ev.cost), 2),
           sum(ev.refunds),
           round(sum(ev.loss), 2),
           sum(ev.exp),
           sum(ev.sales) - sum(ev.refunds) - round(sum(ev.cost), 2) - round(sum(ev.loss), 2) - sum(ev.exp)
      from ev
     group by ev.m
     order by ev.m desc;
end $$;

create or replace function public.owner_profit_by_product(p_from date, p_to date)
returns table (product_id uuid, code text, name text, pieces bigint, net_sales numeric, cogs numeric, profit numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    with ev as (
      select i.product_id as pid, i.product_code as pcode, i.product_name as pname,
             i.quantity as q, i.net_total as amt, coalesce(c.cost_total, 0) as cost
        from public.sale_items i
        join public.sales s on s.id = i.sale_id
        left join private.sale_costs c on c.sale_item_id = i.id
       where s.status = 'completed' and internal.kdate(s.completed_at) between p_from and p_to
      union all
      select ri.product_id, ri.product_code, ri.product_name,
             -ri.quantity, -ri.refund_amount, -coalesce(rc.cost_total, 0)
        from public.sale_return_items ri
        join public.sale_returns r on r.id = ri.return_id
        left join private.sale_return_costs rc on rc.return_item_id = ri.id
       where internal.kdate(r.created_at) between p_from and p_to
    )
    select ev.pid, max(ev.pcode), max(ev.pname), sum(ev.q)::bigint, sum(ev.amt),
           round(sum(ev.cost), 2), sum(ev.amt) - round(sum(ev.cost), 2)
      from ev
     group by ev.pid
     order by 7 desc, 4 desc
     limit 1000;
end $$;

-- =====================================================================
-- 5. SHOPKEEPER LEDGER (khata)
-- =====================================================================
-- One row per customer. Profit only for the owner with the private area open.
create or replace function public.customer_ledger(p_search text default null, p_type public.customer_type default null)
returns table (customer_id uuid, name text, phone text, address text, customer_type public.customer_type,
               bills bigint, total_amount numeric, returns_amount numeric, last_sale_at timestamptz, profit numeric)
language plpgsql stable security definer set search_path = '' as $$
declare v_owner boolean := internal.is_owner_unlocked();
begin
  perform internal.require_active();
  return query
    select c.id, c.name, c.phone, c.address, c.customer_type,
           coalesce(st.bills, 0), coalesce(st.amount, 0) - coalesce(rt.refunds, 0), coalesce(rt.refunds, 0),
           st.last_at,
           case when v_owner then
             coalesce(st.amount, 0) - coalesce(rt.refunds, 0)
             - round(coalesce(st.cost, 0) - coalesce(rt.cost, 0), 2)
           end
      from public.customers c
      left join lateral (
        select count(*)::bigint as bills, sum(s.total) as amount, max(s.completed_at) as last_at,
               (select sum(sc.cost_total) from private.sale_costs sc
                  join public.sales s2 on s2.id = sc.sale_id
                 where s2.customer_id = c.id and s2.status = 'completed') as cost
          from public.sales s where s.customer_id = c.id and s.status = 'completed'
      ) st on true
      left join lateral (
        select sum(r.refund_amount) as refunds,
               (select sum(rc.cost_total) from private.sale_return_costs rc
                  join public.sale_returns r2 on r2.id = rc.return_id where r2.customer_id = c.id) as cost
          from public.sale_returns r where r.customer_id = c.id
      ) rt on true
     where c.is_active
       and (p_type is null or c.customer_type = p_type)
       and (p_search is null or btrim(p_search) = ''
            or c.name ilike '%' || btrim(p_search) || '%'
            or c.phone ilike '%' || btrim(p_search) || '%')
     order by st.last_at desc nulls last, c.name
     limit 1000;
end $$;

-- What one shop buys: pieces, amount, last rate.
create or replace function public.customer_products(p_customer_id uuid)
returns table (product_id uuid, code text, name text, pieces bigint, amount numeric,
               last_price numeric, last_sold_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_active();
  return query
    with sold as (
      select i.product_id as pid, max(i.product_code) as pcode, max(i.product_name) as pname,
             sum(i.quantity) as q, sum(i.net_total) as amt, max(s.completed_at) as last_at
        from public.sale_items i join public.sales s on s.id = i.sale_id
       where s.customer_id = p_customer_id and s.status = 'completed'
       group by i.product_id
    ), ret as (
      select ri.product_id as pid, sum(ri.quantity) as q, sum(ri.refund_amount) as amt
        from public.sale_return_items ri join public.sale_returns r on r.id = ri.return_id
       where r.customer_id = p_customer_id
       group by ri.product_id
    ), lastp as (
      select distinct on (i.product_id) i.product_id as pid, i.unit_price
        from public.sale_items i join public.sales s on s.id = i.sale_id
       where s.customer_id = p_customer_id and s.status = 'completed'
       order by i.product_id, s.completed_at desc
    )
    select sold.pid, sold.pcode, sold.pname, (sold.q - coalesce(ret.q, 0))::bigint,
           sold.amt - coalesce(ret.amt, 0), lastp.unit_price, sold.last_at
      from sold left join ret on ret.pid = sold.pid left join lastp on lastp.pid = sold.pid
     order by sold.q desc, sold.pname;
end $$;

-- Edit a shop's name / phone / address (owner) - saved in History.
create or replace function public.owner_update_customer(p_customer_id uuid, p_name text, p_phone text, p_address text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_old public.customers; v_new public.customers;
begin
  perform internal.require_owner();
  if btrim(coalesce(p_name, '')) = '' then
    raise exception 'Name is required' using errcode = '22023';
  end if;
  select * into v_old from public.customers where id = p_customer_id for update;
  if v_old.id is null then
    raise exception 'Customer not found' using errcode = 'P0002';
  end if;
  update public.customers
     set name = btrim(p_name), phone = btrim(coalesce(p_phone, '')), address = btrim(coalesce(p_address, ''))
   where id = p_customer_id
  returning * into v_new;
  perform internal.audit('customer_updated', 'customer', p_customer_id::text, null,
    jsonb_build_object('name', v_old.name, 'phone', v_old.phone, 'address', v_old.address),
    jsonb_build_object('name', v_new.name, 'phone', v_new.phone, 'address', v_new.address));
end $$;

-- =====================================================================
-- Grants
-- =====================================================================
revoke execute on function internal.kdate(timestamptz) from public, anon, authenticated;
revoke execute on function
  public.owner_adjust_stock(uuid, integer, text, text, numeric),
  public.owner_list_adjustments(uuid, integer),
  public.owner_create_sale_return(uuid, jsonb, text, public.payment_method, uuid),
  public.owner_save_expense(uuid, date, text, numeric, text, text),
  public.owner_delete_expense(uuid, text),
  public.owner_list_expenses(date, date),
  public.owner_profit_by_month(date, date),
  public.customer_ledger(text, public.customer_type),
  public.customer_products(uuid),
  public.owner_update_customer(uuid, text, text, text)
  from public, anon;
grant execute on function
  public.owner_adjust_stock(uuid, integer, text, text, numeric),
  public.owner_list_adjustments(uuid, integer),
  public.owner_create_sale_return(uuid, jsonb, text, public.payment_method, uuid),
  public.owner_save_expense(uuid, date, text, numeric, text, text),
  public.owner_delete_expense(uuid, text),
  public.owner_list_expenses(date, date),
  public.owner_profit_by_month(date, date),
  public.customer_ledger(text, public.customer_type),
  public.customer_products(uuid),
  public.owner_update_customer(uuid, text, text, text)
  to authenticated;
