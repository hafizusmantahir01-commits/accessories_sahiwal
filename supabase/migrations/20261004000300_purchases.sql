-- =====================================================================
-- Accessories Sahiwal — Stage 2b: Suppliers, opening stock, purchases,
-- payments. Everything here is OWNER-ONLY (private area must be unlocked).
-- =====================================================================

create type public.purchase_status as enum ('draft', 'posted');
create type public.payment_direction as enum ('in', 'out');

create table private.suppliers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(btrim(name)) between 1 and 120),
  phone       text not null default '' check (char_length(phone) <= 40),
  address     text not null default '' check (char_length(address) <= 300),
  notes       text not null default '' check (char_length(notes) <= 1000),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index suppliers_name_uq on private.suppliers (lower(btrim(name)));
create trigger suppliers_touch before update on private.suppliers
  for each row execute function internal.touch_updated_at();

create sequence private.purchase_no_seq start 1;

create table private.purchases (
  id                 uuid primary key default gen_random_uuid(),
  purchase_no        text unique,                       -- assigned at posting: PUR-000001
  status             public.purchase_status not null default 'draft',
  supplier_id        uuid not null references private.suppliers(id) on delete restrict,
  document_date      date not null default (now() at time zone 'Asia/Karachi')::date,
  supplier_ref       text not null default '' check (char_length(supplier_ref) <= 80),
  merchandise_total  numeric(14,2) not null default 0 check (merchandise_total >= 0),
  extra_costs        numeric(14,2) not null default 0 check (extra_costs >= 0),
  extra_costs_note   text not null default '' check (char_length(extra_costs_note) <= 200),
  total              numeric(14,2) not null default 0 check (total >= 0),
  payment_method     public.payment_method not null default 'cash',
  notes              text not null default '' check (char_length(notes) <= 2000),
  idempotency_key    uuid unique,
  created_by         uuid references auth.users(id) on delete set null default auth.uid(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  posted_by          uuid references auth.users(id) on delete set null,
  posted_at          timestamptz,
  check ((status = 'posted') = (posted_at is not null and purchase_no is not null))
);
create index purchases_status_idx on private.purchases (status, posted_at desc);
create index purchases_supplier_idx on private.purchases (supplier_id, supplier_ref);
create trigger purchases_touch before update on private.purchases
  for each row execute function internal.touch_updated_at();

create table private.purchase_items (
  id                 uuid primary key default gen_random_uuid(),
  purchase_id        uuid not null references private.purchases(id) on delete cascade,
  line_no            integer not null check (line_no > 0),
  product_id         uuid not null references public.products(id) on delete restrict,
  quantity           integer not null check (quantity > 0),
  unit_price         numeric(14,2) not null check (unit_price >= 0),
  line_discount      numeric(14,2) not null default 0 check (line_discount >= 0),
  merchandise_value  numeric(14,2) not null default 0 check (merchandise_value >= 0),
  allocated_extra    numeric(14,2) not null default 0 check (allocated_extra >= 0),
  landed_value       numeric(14,2) not null default 0 check (landed_value >= 0),
  landed_unit_cost   numeric(18,6) not null default 0 check (landed_unit_cost >= 0),
  unique (purchase_id, line_no),
  check (line_discount <= quantity * unit_price)
);
create index purchase_items_product_idx on private.purchase_items (product_id);

-- Payments are stored ONCE here and linked to their source transaction.
create table private.payments (
  id            uuid primary key default gen_random_uuid(),
  direction     public.payment_direction not null,
  source_type   text not null check (source_type in ('purchase', 'sale', 'sale_refund', 'purchase_refund', 'expense')),
  source_id     uuid not null,
  method        public.payment_method not null,
  amount        numeric(14,2) not null check (amount > 0),     -- applied amount
  tendered      numeric(14,2) check (tendered is null or tendered >= amount),
  change_given  numeric(14,2) not null default 0 check (change_given >= 0),
  reference     text not null default '' check (char_length(reference) <= 80),
  actor_id      uuid references auth.users(id) on delete set null default auth.uid(),
  created_at    timestamptz not null default now(),
  unique (source_type, source_id)
);
create index payments_created_idx on private.payments (created_at desc);

create table private.opening_stock_entries (
  id               uuid primary key default gen_random_uuid(),
  idempotency_key  uuid not null unique,
  product_id       uuid not null references public.products(id) on delete restrict,
  quantity         integer not null check (quantity > 0),
  unit_cost        numeric(14,2) not null check (unit_cost >= 0),
  total_value      numeric(14,2) not null check (total_value >= 0),
  note             text not null default '' check (char_length(note) <= 500),
  created_by       uuid references auth.users(id) on delete set null default auth.uid(),
  created_at       timestamptz not null default now()
);
create index opening_stock_product_idx on private.opening_stock_entries (product_id);

-- =====================================================================
-- RLS (owner + unlocked only)
-- =====================================================================
alter table private.suppliers enable row level security;
alter table private.purchases enable row level security;
alter table private.purchase_items enable row level security;
alter table private.payments enable row level security;
alter table private.opening_stock_entries enable row level security;

create policy suppliers_owner_select on private.suppliers for select to authenticated
  using ((select internal.is_owner_unlocked()));
create policy suppliers_owner_insert on private.suppliers for insert to authenticated
  with check ((select internal.is_owner_unlocked()));
create policy suppliers_owner_update on private.suppliers for update to authenticated
  using ((select internal.is_owner_unlocked())) with check ((select internal.is_owner_unlocked()));
create policy purchases_owner_select on private.purchases for select to authenticated
  using ((select internal.is_owner_unlocked()));
create policy purchase_items_owner_select on private.purchase_items for select to authenticated
  using ((select internal.is_owner_unlocked()));
create policy payments_owner_select on private.payments for select to authenticated
  using ((select internal.is_owner_unlocked()));
create policy opening_owner_select on private.opening_stock_entries for select to authenticated
  using ((select internal.is_owner_unlocked()));

revoke all on private.suppliers, private.purchases, private.purchase_items,
  private.payments, private.opening_stock_entries from anon, authenticated;
grant select, insert, update on private.suppliers to authenticated;
grant select on private.purchases, private.purchase_items, private.payments,
  private.opening_stock_entries to authenticated;

-- =====================================================================
-- Internal: deterministic landed-cost allocation
--   Extra (transport/other) costs are spread by line merchandise value;
--   if every line value is zero, by quantity. The rounding remainder goes
--   to the line with the largest basis (then lowest line_no).
-- =====================================================================
create or replace function internal.allocate_purchase(p_purchase_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_extra numeric(14,2); v_merch numeric(14,2); v_qty bigint; v_alloc_sum numeric(14,2);
  v_use_value boolean;
begin
  update private.purchase_items
     set merchandise_value = quantity * unit_price - line_discount
   where purchase_id = p_purchase_id;

  select extra_costs into v_extra from private.purchases where id = p_purchase_id;
  select coalesce(sum(merchandise_value), 0), coalesce(sum(quantity), 0)
    into v_merch, v_qty from private.purchase_items where purchase_id = p_purchase_id;

  v_use_value := v_merch > 0;
  if v_qty = 0 then
    update private.purchases set merchandise_total = 0, total = extra_costs where id = p_purchase_id;
    return;
  end if;

  update private.purchase_items
     set allocated_extra = case when v_extra = 0 then 0
                                when v_use_value then round(v_extra * merchandise_value / v_merch, 2)
                                else round(v_extra * quantity / v_qty, 2) end
   where purchase_id = p_purchase_id;

  select coalesce(sum(allocated_extra), 0) into v_alloc_sum
    from private.purchase_items where purchase_id = p_purchase_id;

  if v_alloc_sum <> v_extra then
    update private.purchase_items
       set allocated_extra = allocated_extra + (v_extra - v_alloc_sum)
     where id = (select id from private.purchase_items
                  where purchase_id = p_purchase_id
                  order by case when v_use_value then merchandise_value else quantity end desc, line_no
                  limit 1);
  end if;

  update private.purchase_items
     set landed_value = merchandise_value + allocated_extra,
         landed_unit_cost = round((merchandise_value + allocated_extra) / quantity, 6)
   where purchase_id = p_purchase_id;

  update private.purchases
     set merchandise_total = v_merch, total = v_merch + extra_costs
   where id = p_purchase_id;
end $$;

-- =====================================================================
-- RPC: opening stock
-- =====================================================================
create or replace function public.owner_post_opening_stock(
  p_product_id uuid, p_quantity integer, p_unit_cost numeric,
  p_idempotency_key uuid, p_note text default '')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_value numeric(14,2);
begin
  perform internal.require_owner_unlocked();
  if p_idempotency_key is null then
    raise exception 'Missing idempotency key' using errcode = '22023';
  end if;
  select id into v_id from private.opening_stock_entries where idempotency_key = p_idempotency_key;
  if v_id is not null then
    return v_id;                                  -- retry of an already-posted request
  end if;
  if (select trading_started_at from public.business_settings where id = 1) is not null then
    raise exception 'Trading has started. Use a stock adjustment instead of opening stock.'
      using errcode = '55000';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantity must be a positive whole number' using errcode = '22023';
  end if;
  if p_unit_cost is null or p_unit_cost < 0 or p_unit_cost <> round(p_unit_cost, 2) then
    raise exception 'Unit cost must be zero or more with at most 2 decimals' using errcode = '22023';
  end if;
  if not exists (select 1 from public.products where id = p_product_id) then
    raise exception 'Product not found' using errcode = 'P0002';
  end if;

  v_value := round(p_quantity * p_unit_cost, 2);
  insert into private.opening_stock_entries (idempotency_key, product_id, quantity, unit_cost, total_value, note)
  values (p_idempotency_key, p_product_id, p_quantity, p_unit_cost, v_value, coalesce(p_note, ''))
  on conflict (idempotency_key) do nothing
  returning id into v_id;
  if v_id is null then  -- lost a race with an identical retry
    select id into v_id from private.opening_stock_entries where idempotency_key = p_idempotency_key;
    return v_id;
  end if;

  perform internal.lock_balances(array[p_product_id]);
  perform internal.receive_stock(p_product_id, p_quantity, v_value, 'opening',
                                 'opening_stock', v_id, null, nullif(p_note, ''));
  perform internal.audit('opening_stock_posted', 'opening_stock', v_id::text, null, null,
    jsonb_build_object('product_id', p_product_id, 'quantity', p_quantity, 'unit_cost', p_unit_cost));
  return v_id;
end $$;

create or replace function public.owner_start_trading()
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare v_ts timestamptz;
begin
  perform internal.require_owner_unlocked();
  update public.business_settings set trading_started_at = coalesce(trading_started_at, now())
   where id = 1 returning trading_started_at into v_ts;
  perform internal.audit('trading_started', 'business_settings', '1');
  return v_ts;
end $$;

-- =====================================================================
-- RPC: purchases
-- =====================================================================

-- Create or replace a DRAFT purchase. Drafts change neither stock nor money.
-- p_data: { id?, supplier_id, document_date, supplier_ref, extra_costs,
--           extra_costs_note, payment_method, notes,
--           items: [{ product_id, quantity, unit_price, line_discount }] }
create or replace function public.owner_save_purchase_draft(p_data jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := nullif(p_data ->> 'id', '')::uuid;
  v_status public.purchase_status;
  v_item jsonb; v_line integer := 0;
  v_extra numeric := coalesce(nullif(p_data ->> 'extra_costs', '')::numeric, 0);
begin
  perform internal.require_owner_unlocked();
  if nullif(p_data ->> 'supplier_id', '') is null then
    raise exception 'Supplier is required' using errcode = '22023';
  end if;
  if v_extra < 0 or v_extra <> round(v_extra, 2) then
    raise exception 'Extra costs must be zero or more with at most 2 decimals' using errcode = '22023';
  end if;
  if jsonb_typeof(p_data -> 'items') is distinct from 'array' or jsonb_array_length(p_data -> 'items') = 0 then
    raise exception 'Add at least one product' using errcode = '22023';
  end if;

  if v_id is null then
    insert into private.purchases (supplier_id, document_date, supplier_ref, extra_costs,
                                   extra_costs_note, payment_method, notes)
    values ((p_data ->> 'supplier_id')::uuid,
            coalesce(nullif(p_data ->> 'document_date', '')::date, (now() at time zone 'Asia/Karachi')::date),
            btrim(coalesce(p_data ->> 'supplier_ref', '')), v_extra,
            btrim(coalesce(p_data ->> 'extra_costs_note', '')),
            coalesce(nullif(p_data ->> 'payment_method', ''), 'cash')::public.payment_method,
            coalesce(p_data ->> 'notes', ''))
    returning id into v_id;
  else
    select status into v_status from private.purchases where id = v_id for update;
    if v_status is null then
      raise exception 'Purchase not found' using errcode = 'P0002';
    elsif v_status <> 'draft' then
      raise exception 'Posted purchases cannot be edited' using errcode = '55000';
    end if;
    update private.purchases
       set supplier_id = (p_data ->> 'supplier_id')::uuid,
           document_date = coalesce(nullif(p_data ->> 'document_date', '')::date, document_date),
           supplier_ref = btrim(coalesce(p_data ->> 'supplier_ref', '')),
           extra_costs = v_extra,
           extra_costs_note = btrim(coalesce(p_data ->> 'extra_costs_note', '')),
           payment_method = coalesce(nullif(p_data ->> 'payment_method', ''), 'cash')::public.payment_method,
           notes = coalesce(p_data ->> 'notes', '')
     where id = v_id;
    delete from private.purchase_items where purchase_id = v_id;
  end if;

  if (select document_date from private.purchases where id = v_id) > (now() at time zone 'Asia/Karachi')::date then
    raise exception 'Supplier bill date cannot be in the future' using errcode = '22023';
  end if;

  for v_item in select * from jsonb_array_elements(p_data -> 'items') loop
    v_line := v_line + 1;
    if (v_item ->> 'quantity')::numeric <> trunc((v_item ->> 'quantity')::numeric)
       or (v_item ->> 'quantity')::numeric <= 0 then
      raise exception 'Line %: quantity must be a positive whole number', v_line using errcode = '22023';
    end if;
    if (v_item ->> 'unit_price')::numeric < 0
       or (v_item ->> 'unit_price')::numeric <> round((v_item ->> 'unit_price')::numeric, 2) then
      raise exception 'Line %: unit price must be zero or more with at most 2 decimals', v_line using errcode = '22023';
    end if;
    insert into private.purchase_items (purchase_id, line_no, product_id, quantity, unit_price, line_discount)
    values (v_id, v_line, (v_item ->> 'product_id')::uuid, (v_item ->> 'quantity')::integer,
            (v_item ->> 'unit_price')::numeric,
            coalesce(nullif(v_item ->> 'line_discount', '')::numeric, 0));
  end loop;

  perform internal.allocate_purchase(v_id);
  return v_id;
exception
  when check_violation then
    raise exception 'Invalid line: discount cannot exceed the line value, and amounts must be positive'
      using errcode = '23514';
end $$;

-- Post a draft as FULLY PAID. Atomic: lines, stock movements, average costs, payment.
create or replace function public.owner_post_purchase(
  p_purchase_id uuid, p_payment_method public.payment_method, p_amount_paid numeric,
  p_idempotency_key uuid, p_reference text default '')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_p private.purchases; v_item record; v_ids uuid[];
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
    -- Idempotent: a retry returns the original result without posting twice.
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

  for v_item in
    select * from private.purchase_items where purchase_id = p_purchase_id order by product_id, line_no
  loop
    perform internal.receive_stock(v_item.product_id, v_item.quantity, v_item.landed_value,
                                   'purchase', 'purchase', p_purchase_id, v_item.id, null);
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
         posted_at = now(), posted_by = auth.uid()
   where id = p_purchase_id
  returning * into v_p;

  perform internal.audit('purchase_posted', 'purchase', p_purchase_id::text, null, null,
    jsonb_build_object('purchase_no', v_p.purchase_no, 'total', v_p.total, 'method', p_payment_method));

  return jsonb_build_object('id', v_p.id, 'purchase_no', v_p.purchase_no,
                            'total', v_p.total, 'already_posted', false);
end $$;

create or replace function public.owner_delete_purchase_draft(p_purchase_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  delete from private.purchases where id = p_purchase_id and status = 'draft';
  if not found then
    raise exception 'Only draft purchases can be deleted' using errcode = '55000';
  end if;
end $$;

create or replace function public.owner_list_purchases(
  p_from date default null, p_to date default null, p_status public.purchase_status default null,
  p_search text default null)
returns table (id uuid, purchase_no text, status public.purchase_status, supplier_name text,
               supplier_ref text, document_date date, total numeric, payment_method public.payment_method,
               item_count bigint, created_at timestamptz, posted_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select p.id, p.purchase_no, p.status, s.name, p.supplier_ref, p.document_date, p.total,
           p.payment_method, (select count(*) from private.purchase_items i where i.purchase_id = p.id),
           p.created_at, p.posted_at
      from private.purchases p
      join private.suppliers s on s.id = p.supplier_id
     where (p_status is null or p.status = p_status)
       and (p_from is null or coalesce((p.posted_at at time zone 'Asia/Karachi')::date, p.document_date) >= p_from)
       and (p_to   is null or coalesce((p.posted_at at time zone 'Asia/Karachi')::date, p.document_date) <= p_to)
       and (p_search is null or btrim(p_search) = ''
            or s.name ilike '%' || btrim(p_search) || '%'
            or p.supplier_ref ilike '%' || btrim(p_search) || '%'
            or p.purchase_no ilike '%' || btrim(p_search) || '%')
     order by p.status, coalesce(p.posted_at, p.created_at) desc
     limit 500;
end $$;

create or replace function public.owner_get_purchase(p_purchase_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform internal.require_owner_unlocked();
  select to_jsonb(p) || jsonb_build_object(
           'supplier', jsonb_build_object('id', s.id, 'name', s.name, 'phone', s.phone),
           'payment', (select to_jsonb(pay) from private.payments pay
                        where pay.source_type = 'purchase' and pay.source_id = p.id),
           'items', coalesce((select jsonb_agg(to_jsonb(i) || jsonb_build_object(
                                     'product_code', pr.code, 'product_name', pr.name) order by i.line_no)
                                from private.purchase_items i join public.products pr on pr.id = i.product_id
                               where i.purchase_id = p.id), '[]'::jsonb))
    into v
    from private.purchases p join private.suppliers s on s.id = p.supplier_id
   where p.id = p_purchase_id;
  if v is null then
    raise exception 'Purchase not found' using errcode = 'P0002';
  end if;
  return v;
end $$;

-- Optional duplicate supplier bill warning (does not block).
create or replace function public.owner_find_duplicate_supplier_ref(
  p_supplier_id uuid, p_supplier_ref text, p_exclude_id uuid default null)
returns table (id uuid, purchase_no text, status public.purchase_status, document_date date, total numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select p.id, p.purchase_no, p.status, p.document_date, p.total
      from private.purchases p
     where p.supplier_id = p_supplier_id
       and btrim(coalesce(p_supplier_ref, '')) <> ''
       and lower(p.supplier_ref) = lower(btrim(p_supplier_ref))
       and (p_exclude_id is null or p.id <> p_exclude_id);
end $$;

-- Owner-only cost details for one product (product screen in private mode).
create or replace function public.owner_product_cost(p_product_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_result jsonb;
begin
  perform internal.require_owner_unlocked();
  select jsonb_build_object(
           'product_id', iv.product_id, 'average_cost', iv.average_cost,
           'carrying_value', round(iv.carrying_value, 2), 'saleable_qty', b.saleable_qty,
           'recent_movements', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'posted_at', m.posted_at, 'type', m.movement_type, 'quantity', m.quantity,
                       'unit_cost', m.unit_cost, 'value_change', round(m.value_change, 2),
                       'qty_after', m.qty_after, 'reason', m.reason) order by m.posted_at desc, m.id desc)
                from (select * from private.stock_movements sm where sm.product_id = p_product_id
                       order by sm.posted_at desc, sm.id desc limit 50) m), '[]'::jsonb))
    into v_result
    from private.inventory_valuation iv join public.inventory_balances b on b.product_id = iv.product_id
   where iv.product_id = p_product_id;
  return v_result;
end $$;

-- =====================================================================
-- Reconciliation check: balances must equal the movement ledger.
-- =====================================================================
create or replace function public.owner_reconcile_inventory()
returns table (product_id uuid, code text, balance_qty integer, ledger_qty bigint,
               valuation numeric, ledger_value numeric, ok boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select p.id, p.code, b.saleable_qty,
           coalesce(sum(m.quantity) filter (where m.bucket = 'saleable'), 0),
           v.carrying_value,
           coalesce(sum(m.value_change) filter (where m.bucket = 'saleable'), 0),
           b.saleable_qty = coalesce(sum(m.quantity) filter (where m.bucket = 'saleable'), 0)
             and v.carrying_value = coalesce(sum(m.value_change) filter (where m.bucket = 'saleable'), 0)
             and b.non_saleable_qty = coalesce(sum(m.quantity) filter (where m.bucket = 'non_saleable'), 0)
      from public.products p
      join public.inventory_balances b on b.product_id = p.id
      join private.inventory_valuation v on v.product_id = p.id
      left join private.stock_movements m on m.product_id = p.id
     group by p.id, p.code, b.saleable_qty, b.non_saleable_qty, v.carrying_value
     order by 7, p.code;
end $$;

-- =====================================================================
-- Grants
-- =====================================================================
revoke execute on function
  public.owner_post_opening_stock(uuid, integer, numeric, uuid, text),
  public.owner_start_trading(),
  public.owner_save_purchase_draft(jsonb),
  public.owner_post_purchase(uuid, public.payment_method, numeric, uuid, text),
  public.owner_delete_purchase_draft(uuid),
  public.owner_list_purchases(date, date, public.purchase_status, text),
  public.owner_get_purchase(uuid),
  public.owner_find_duplicate_supplier_ref(uuid, text, uuid),
  public.owner_product_cost(uuid),
  public.owner_reconcile_inventory()
  from public, anon;
grant execute on function
  public.owner_post_opening_stock(uuid, integer, numeric, uuid, text),
  public.owner_start_trading(),
  public.owner_save_purchase_draft(jsonb),
  public.owner_post_purchase(uuid, public.payment_method, numeric, uuid, text),
  public.owner_delete_purchase_draft(uuid),
  public.owner_list_purchases(date, date, public.purchase_status, text),
  public.owner_get_purchase(uuid),
  public.owner_find_duplicate_supplier_ref(uuid, text, uuid),
  public.owner_product_cost(uuid),
  public.owner_reconcile_inventory()
  to authenticated;

revoke execute on all functions in schema internal from public, anon, authenticated;
grant execute on function
  internal.is_active_user(), internal.is_owner(), internal.is_owner_unlocked(),
  internal.has_permission(text), internal.jwt_claims(), internal.current_session_id(),
  internal.current_auth_time()
  to authenticated;
