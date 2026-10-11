-- =====================================================================
-- 1. Day closing (cash count): expected cash vs counted cash
-- 2. Dead stock: stock that has not sold for N days (money stuck)
-- 3. Daily report for the dashboard graph
-- 4. Bulk price change (preview + apply, logged)
-- 5. Reorder suggestions from selling speed
-- 6. Excel export (backup) data
-- Expenses get "paid from galla (cash)" so the day closing is exact.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Expenses: paid from the cash drawer or not
-- ---------------------------------------------------------------------
alter table private.expenses add column if not exists paid_from_cash boolean not null default true;

drop function if exists public.owner_save_expense(uuid, date, text, numeric, text, text);
create or replace function public.owner_save_expense(
  p_id uuid, p_date date, p_category text, p_amount numeric, p_note text default '',
  p_reason text default null, p_from_cash boolean default true)
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
    insert into private.expenses (expense_date, category, amount, note, paid_from_cash)
    values (p_date, v_cat, p_amount, btrim(coalesce(p_note, '')), coalesce(p_from_cash, true))
    returning * into v_new;
    perform internal.audit('expense_added', 'expense', v_new.id::text, null, null,
      jsonb_build_object('date', v_new.expense_date, 'category', v_cat, 'amount', v_new.amount,
                         'note', v_new.note, 'from_cash', v_new.paid_from_cash));
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
           note = btrim(coalesce(p_note, '')), paid_from_cash = coalesce(p_from_cash, true), updated_at = now()
     where id = p_id
    returning * into v_new;
    perform internal.audit('expense_edited', 'expense', p_id::text, btrim(p_reason),
      jsonb_build_object('date', v_old.expense_date, 'category', v_old.category, 'amount', v_old.amount,
                         'note', v_old.note, 'from_cash', v_old.paid_from_cash),
      jsonb_build_object('date', v_new.expense_date, 'category', v_new.category, 'amount', v_new.amount,
                         'note', v_new.note, 'from_cash', v_new.paid_from_cash));
  end if;
  return v_new.id;
end $$;

drop function if exists public.owner_list_expenses(date, date);
create function public.owner_list_expenses(p_from date, p_to date)
returns table (id uuid, expense_date date, category text, amount numeric, note text,
               created_by_name text, created_at timestamptz, paid_from_cash boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select e.id, e.expense_date, e.category, e.amount, e.note,
           coalesce(nullif(pr.full_name, ''), 'User'), e.created_at, e.paid_from_cash
      from private.expenses e left join public.profiles pr on pr.id = e.created_by
     where e.expense_date between p_from and p_to
     order by e.expense_date desc, e.created_at desc
     limit 2000;
end $$;

-- =====================================================================
-- 1. DAY CLOSING
-- =====================================================================
create table if not exists private.day_closings (
  closing_date   date primary key,
  opening_cash   numeric(14,2) not null default 0 check (opening_cash >= 0),
  cash_sales     numeric(14,2) not null default 0,
  cash_refunds   numeric(14,2) not null default 0,
  cash_expenses  numeric(14,2) not null default 0,
  cash_out       numeric(14,2) not null default 0 check (cash_out >= 0),
  expected_cash  numeric(14,2) not null,
  counted_cash   numeric(14,2) not null check (counted_cash >= 0),
  difference     numeric(14,2) not null,
  note           text not null default '' check (char_length(note) <= 300),
  closed_by      uuid references auth.users(id) on delete set null default auth.uid(),
  closed_at      timestamptz not null default now()
);
alter table private.day_closings enable row level security;
revoke all on private.day_closings from anon, authenticated;

create or replace function internal.require_can_sell()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not internal.has_permission('create_sale') then
    raise exception 'You do not have permission to do this' using errcode = '42501';
  end if;
end $$;

-- Cash figures of one day + the last closing (for the opening cash).
create or replace function public.day_cash_summary(p_date date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_prev private.day_closings; v_this private.day_closings;
begin
  perform internal.require_can_sell();
  select * into v_prev from private.day_closings where closing_date < p_date order by closing_date desc limit 1;
  select * into v_this from private.day_closings where closing_date = p_date;
  select jsonb_build_object(
    'date', p_date,
    'opening_default', coalesce(v_prev.counted_cash, 0),
    'previous_date', v_prev.closing_date,
    'cash_sales', coalesce((select sum(s.total) from public.sales s
                             where s.status = 'completed' and s.payment_method = 'cash'
                               and internal.kdate(s.completed_at) = p_date), 0),
    'cash_refunds', coalesce((select sum(r.refund_amount) from public.sale_returns r
                               where r.refund_method = 'cash' and internal.kdate(r.created_at) = p_date), 0),
    'cash_expenses', coalesce((select sum(e.amount) from private.expenses e
                                where e.paid_from_cash and e.expense_date = p_date), 0),
    'bills', (select count(*) from public.sales s where s.status = 'completed' and internal.kdate(s.completed_at) = p_date),
    'other_methods', coalesce((select jsonb_object_agg(m, amt) from (
                        select s.payment_method::text as m, sum(s.total) as amt from public.sales s
                         where s.status = 'completed' and s.payment_method <> 'cash'
                           and internal.kdate(s.completed_at) = p_date
                         group by s.payment_method) x), '{}'::jsonb),
    'closing', case when v_this.closing_date is null then null else to_jsonb(v_this) end)
  into v;
  return v;
end $$;

-- Save (or redo, with a reason) the closing of one day.
create or replace function public.close_day(
  p_date date, p_opening numeric, p_cash_out numeric, p_counted numeric,
  p_note text default '', p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_sum jsonb; v_old private.day_closings; v_new private.day_closings; v_expected numeric(14,2);
begin
  perform internal.require_can_sell();
  if p_date is null or p_date > (now() at time zone 'Asia/Karachi')::date then
    raise exception 'Date cannot be in the future' using errcode = '22023';
  end if;
  if coalesce(p_opening, -1) < 0 or coalesce(p_cash_out, -1) < 0 or coalesce(p_counted, -1) < 0
     or p_opening <> round(p_opening, 2) or p_cash_out <> round(p_cash_out, 2) or p_counted <> round(p_counted, 2) then
    raise exception 'Amounts must be zero or more with at most 2 decimals' using errcode = '22023';
  end if;
  select * into v_old from private.day_closings where closing_date = p_date for update;
  if v_old.closing_date is not null and btrim(coalesce(p_reason, '')) = '' then
    raise exception 'This day is already closed. Write a reason to change it.' using errcode = '22023';
  end if;
  v_sum := public.day_cash_summary(p_date);
  v_expected := p_opening + (v_sum ->> 'cash_sales')::numeric - (v_sum ->> 'cash_refunds')::numeric
                - (v_sum ->> 'cash_expenses')::numeric - p_cash_out;
  insert into private.day_closings (closing_date, opening_cash, cash_sales, cash_refunds, cash_expenses, cash_out,
                                    expected_cash, counted_cash, difference, note)
  values (p_date, p_opening, (v_sum ->> 'cash_sales')::numeric, (v_sum ->> 'cash_refunds')::numeric,
          (v_sum ->> 'cash_expenses')::numeric, p_cash_out, v_expected, p_counted, p_counted - v_expected,
          btrim(coalesce(p_note, '')))
  on conflict (closing_date) do update
     set opening_cash = excluded.opening_cash, cash_sales = excluded.cash_sales,
         cash_refunds = excluded.cash_refunds, cash_expenses = excluded.cash_expenses,
         cash_out = excluded.cash_out, expected_cash = excluded.expected_cash,
         counted_cash = excluded.counted_cash, difference = excluded.difference, note = excluded.note,
         closed_by = auth.uid(), closed_at = now()
  returning * into v_new;
  perform internal.audit(case when v_old.closing_date is null then 'day_closed' else 'day_closing_changed' end,
    'day_closing', p_date::text, nullif(btrim(coalesce(p_reason, '')), ''),
    case when v_old.closing_date is null then null else to_jsonb(v_old) end, to_jsonb(v_new));
  return to_jsonb(v_new);
end $$;

create or replace function public.owner_list_day_closings(p_limit integer default 60)
returns table (closing_date date, opening_cash numeric, cash_sales numeric, cash_refunds numeric,
               cash_expenses numeric, cash_out numeric, expected_cash numeric, counted_cash numeric,
               difference numeric, note text, closed_by_name text, closed_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner();
  return query
    select d.closing_date, d.opening_cash, d.cash_sales, d.cash_refunds, d.cash_expenses, d.cash_out,
           d.expected_cash, d.counted_cash, d.difference, d.note,
           coalesce(nullif(pr.full_name, ''), 'User'), d.closed_at
      from private.day_closings d left join public.profiles pr on pr.id = d.closed_by
     order by d.closing_date desc
     limit least(greatest(coalesce(p_limit, 60), 1), 1000);
end $$;

-- =====================================================================
-- 2. DEAD STOCK
-- =====================================================================
create or replace function public.owner_dead_stock(p_days integer default 60)
returns table (product_id uuid, code text, name text, qty integer, stock_value numeric,
               last_sold_at timestamptz, days_idle integer)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    with ls as (
      select i.product_id as pid, max(s.completed_at) as last_at
        from public.sale_items i join public.sales s on s.id = i.sale_id
       where s.status = 'completed'
       group by i.product_id
    )
    select p.id, p.code, p.name, b.saleable_qty, round(v.carrying_value, 2), ls.last_at,
           ((now() at time zone 'Asia/Karachi')::date
             - internal.kdate(coalesce(ls.last_at, p.created_at)))::integer
      from public.products p
      join public.inventory_balances b on b.product_id = p.id
      join private.inventory_valuation v on v.product_id = p.id
      left join ls on ls.pid = p.id
     where p.is_active and b.saleable_qty > 0
       and internal.kdate(coalesce(ls.last_at, p.created_at))
           <= (now() at time zone 'Asia/Karachi')::date - greatest(coalesce(p_days, 60), 1)
     order by v.carrying_value desc, p.name
     limit 1000;
end $$;

-- =====================================================================
-- 3. DAILY REPORT (dashboard graph)
-- =====================================================================
create or replace function public.owner_daily_report(p_from date, p_to date)
returns table (day date, bills bigint, net_sales numeric, profit numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  if p_to - p_from > 400 then
    raise exception 'Choose at most 400 days' using errcode = '22023';
  end if;
  return query
    with days as (select generate_series(p_from, p_to, interval '1 day')::date as d),
    s as (
      select internal.kdate(x.completed_at) as d, count(*)::bigint as n, sum(x.total) as amt,
             sum((select coalesce(sum(c.cost_total), 0) from private.sale_costs c where c.sale_id = x.id)) as cost
        from public.sales x
       where x.status = 'completed' and internal.kdate(x.completed_at) between p_from and p_to
       group by 1
    ),
    r as (
      select internal.kdate(y.created_at) as d, sum(y.refund_amount) as amt,
             sum((select coalesce(sum(rc.cost_total), 0) from private.sale_return_costs rc where rc.return_id = y.id)) as cost
        from public.sale_returns y
       where internal.kdate(y.created_at) between p_from and p_to
       group by 1
    )
    select days.d, coalesce(s.n, 0)::bigint,
           coalesce(s.amt, 0) - coalesce(r.amt, 0),
           coalesce(s.amt, 0) - coalesce(r.amt, 0) - round(coalesce(s.cost, 0) - coalesce(r.cost, 0), 2)
      from days left join s on s.d = days.d left join r on r.d = days.d
     order by days.d;
end $$;

-- =====================================================================
-- 4. BULK PRICE CHANGE
-- =====================================================================
-- p_mode 'percent' (e.g. 5 = +5%, -10 = −10%) or 'amount' (Rs, e.g. 20 or -15).
-- p_round: 0 = paisa (2 decimals), else round to nearest 1 / 5 / 10 rupees.
create or replace function internal.bulk_new_price(p_old numeric, p_mode text, p_value numeric, p_round integer)
returns numeric language sql immutable set search_path = '' as $$
  select case when coalesce(p_round, 0) > 0
              then round(x / p_round) * p_round
              else round(x, 2) end
    from (select case when p_mode = 'percent' then p_old * (1 + p_value / 100.0) else p_old + p_value end as x) t
$$;

create or replace function public.owner_bulk_price_preview(
  p_product_ids uuid[], p_field text, p_mode text, p_value numeric, p_round integer default 0)
returns table (product_id uuid, code text, name text, old_retail numeric, new_retail numeric,
               old_wholesale numeric, new_wholesale numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner();
  if p_field not in ('retail', 'wholesale', 'both') or p_mode not in ('percent', 'amount') then
    raise exception 'Choose which price and how to change it' using errcode = '22023';
  end if;
  if p_value is null or p_value = 0 then
    raise exception 'Enter the change (for example 5 or -5)' using errcode = '22023';
  end if;
  if coalesce(p_round, 0) not in (0, 1, 5, 10, 50, 100) then
    raise exception 'Rounding must be 0, 1, 5, 10, 50 or 100' using errcode = '22023';
  end if;
  return query
    select p.id, p.code, p.name, p.retail_price,
           case when p_field in ('retail', 'both') then internal.bulk_new_price(p.retail_price, p_mode, p_value, p_round)
                else p.retail_price end,
           p.wholesale_price,
           case when p_field in ('wholesale', 'both') then internal.bulk_new_price(p.wholesale_price, p_mode, p_value, p_round)
                else p.wholesale_price end
      from public.products p
     where p.id = any(p_product_ids) and p.is_active
     order by p.name;
end $$;

create or replace function public.owner_bulk_price_apply(
  p_product_ids uuid[], p_field text, p_mode text, p_value numeric, p_round integer, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_count integer; v_bad text;
begin
  perform internal.require_owner();
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'Write a short reason (it is saved in History)' using errcode = '22023';
  end if;
  select string_agg(x.code, ', ') into v_bad
    from public.owner_bulk_price_preview(p_product_ids, p_field, p_mode, p_value, p_round) x
   where x.new_retail <= 0 or x.new_wholesale <= 0;
  if v_bad is not null then
    raise exception 'PRICE_ZERO: These prices would become 0 or less: %', v_bad using errcode = '22023';
  end if;
  update public.products p
     set retail_price = x.new_retail, wholesale_price = x.new_wholesale
    from public.owner_bulk_price_preview(p_product_ids, p_field, p_mode, p_value, p_round) x
   where p.id = x.product_id
     and (p.retail_price <> x.new_retail or p.wholesale_price <> x.new_wholesale);
  get diagnostics v_count = row_count;
  perform internal.audit('bulk_price_change', 'product', null, btrim(p_reason), null,
    jsonb_build_object('count', v_count, 'field', p_field, 'mode', p_mode, 'value', p_value, 'round', p_round));
  return v_count;
end $$;

-- =====================================================================
-- 5. REORDER SUGGESTIONS
-- =====================================================================
-- Based on how many pieces sold in the last p_days: enough stock for p_cover days.
create or replace function public.owner_reorder_suggestions(p_days integer default 30, p_cover integer default 15)
returns table (product_id uuid, code text, name text, stock integer, reorder_threshold integer,
               sold integer, per_day numeric, days_left numeric, suggested integer, last_rate numeric)
language plpgsql stable security definer set search_path = '' as $$
declare v_days integer := least(greatest(coalesce(p_days, 30), 7), 365);
        v_cover integer := least(greatest(coalesce(p_cover, 15), 1), 180);
begin
  perform internal.require_owner_unlocked();
  return query
    with sold as (
      select i.product_id as pid, sum(i.quantity) as q
        from public.sale_items i join public.sales s on s.id = i.sale_id
       where s.status = 'completed'
         and internal.kdate(s.completed_at) > (now() at time zone 'Asia/Karachi')::date - v_days
       group by i.product_id
    ), ret as (
      select ri.product_id as pid, sum(ri.quantity) as q
        from public.sale_return_items ri join public.sale_returns r on r.id = ri.return_id
       where internal.kdate(r.created_at) > (now() at time zone 'Asia/Karachi')::date - v_days
       group by ri.product_id
    ), rate as (
      select distinct on (pi.product_id) pi.product_id as pid, pi.unit_price
        from private.purchase_items pi join private.purchases pu on pu.id = pi.purchase_id
       where pu.status = 'posted'
       order by pi.product_id, pu.posted_at desc
    ), calc as (
      select p.id, p.code, p.name, b.saleable_qty as stk, p.reorder_threshold as thr,
             greatest(coalesce(sold.q, 0) - coalesce(ret.q, 0), 0)::integer as sold_q,
             rate.unit_price as lr
        from public.products p
        join public.inventory_balances b on b.product_id = p.id
        left join sold on sold.pid = p.id
        left join ret on ret.pid = p.id
        left join rate on rate.pid = p.id
       where p.is_active
    )
    select c.id, c.code, c.name, c.stk, c.thr, c.sold_q,
           round(c.sold_q::numeric / v_days, 2),
           case when c.sold_q > 0 then round(c.stk / (c.sold_q::numeric / v_days), 1) end,
           greatest(case when c.sold_q > 0 then ceil(c.sold_q::numeric / v_days * v_cover)::integer - c.stk
                         else c.thr - c.stk end, 0),
           c.lr
      from calc c
     where (c.sold_q > 0 and ceil(c.sold_q::numeric / v_days * v_cover) > c.stk)
        or c.stk <= c.thr
     order by case when c.sold_q > 0 then c.stk / (c.sold_q::numeric / v_days) else 9999 end, c.name
     limit 500;
end $$;

-- =====================================================================
-- 6. EXCEL EXPORT (backup) — everything for a period in one call
-- =====================================================================
create or replace function public.owner_export(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform internal.require_owner_unlocked();
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'generated_at', now(),
    'summary', public.owner_profit_summary(p_from, p_to),
    'sales', coalesce((select jsonb_agg(jsonb_build_object(
        'invoice_no', s.invoice_no, 'date', s.completed_at, 'type', s.sale_type, 'status', s.status,
        'customer', s.customer_name, 'phone', s.customer_phone, 'bill', s.subtotal, 'discount', s.discount_amount,
        'discount_reason', s.discount_reason, 'received', s.total, 'method', s.payment_method,
        'cost', (select round(coalesce(sum(c.cost_total), 0), 2) from private.sale_costs c where c.sale_id = s.id),
        'void_reason', s.void_reason) order by s.completed_at)
      from public.sales s where internal.kdate(s.completed_at) between p_from and p_to), '[]'::jsonb),
    'sale_items', coalesce((select jsonb_agg(jsonb_build_object(
        'invoice_no', s.invoice_no, 'date', s.completed_at, 'status', s.status, 'code', i.product_code,
        'name', i.product_name, 'qty', i.quantity, 'list_price', i.list_price, 'price', i.unit_price,
        'line_total', i.line_total, 'discount_share', i.discount_share, 'net', i.net_total,
        'cost', round(coalesce(c.cost_total, 0), 2)) order by s.completed_at, i.line_no)
      from public.sale_items i join public.sales s on s.id = i.sale_id
      left join private.sale_costs c on c.sale_item_id = i.id
      where internal.kdate(s.completed_at) between p_from and p_to), '[]'::jsonb),
    'returns', coalesce((select jsonb_agg(jsonb_build_object(
        'return_no', r.return_no, 'date', r.created_at, 'invoice_no', s.invoice_no, 'customer', r.customer_name,
        'code', ri.product_code, 'name', ri.product_name, 'qty', ri.quantity, 'refund', ri.refund_amount,
        'condition', ri.condition, 'method', r.refund_method, 'reason', r.reason) order by r.created_at)
      from public.sale_return_items ri join public.sale_returns r on r.id = ri.return_id
      join public.sales s on s.id = r.sale_id
      where internal.kdate(r.created_at) between p_from and p_to), '[]'::jsonb),
    'purchases', coalesce((select jsonb_agg(jsonb_build_object(
        'purchase_no', pu.purchase_no, 'date', pu.posted_at, 'supplier', su.name, 'supplier_ref', pu.supplier_ref,
        'code', pr.code, 'name', pr.name, 'qty', pi.quantity, 'rate', pi.unit_price, 'discount', pi.line_discount,
        'extra', pi.allocated_extra, 'total', pi.landed_value, 'unit_cost', round(pi.landed_unit_cost, 2))
        order by pu.posted_at, pi.line_no)
      from private.purchase_items pi join private.purchases pu on pu.id = pi.purchase_id
      join private.suppliers su on su.id = pu.supplier_id join public.products pr on pr.id = pi.product_id
      where pu.status = 'posted' and internal.kdate(pu.posted_at) between p_from and p_to), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(jsonb_build_object(
        'date', e.expense_date, 'category', e.category, 'amount', e.amount, 'note', e.note,
        'from_cash', e.paid_from_cash) order by e.expense_date)
      from private.expenses e where e.expense_date between p_from and p_to), '[]'::jsonb),
    'adjustments', coalesce((select jsonb_agg(jsonb_build_object(
        'date', a.created_at, 'code', p.code, 'name', p.name, 'qty_change', a.qty_change, 'kind', a.kind,
        'note', a.note, 'value_change', a.value_change) order by a.created_at)
      from private.stock_adjustments a join public.products p on p.id = a.product_id
      where internal.kdate(a.created_at) between p_from and p_to), '[]'::jsonb),
    'closings', coalesce((select jsonb_agg(to_jsonb(d) order by d.closing_date)
      from private.day_closings d where d.closing_date between p_from and p_to), '[]'::jsonb),
    'stock', coalesce((select jsonb_agg(jsonb_build_object(
        'code', p.code, 'name', p.name, 'brand', p.brand, 'active', p.is_active, 'qty', b.saleable_qty,
        'damaged', b.non_saleable_qty, 'avg_cost', round(v.average_cost, 2), 'stock_value', round(v.carrying_value, 2),
        'wholesale', p.wholesale_price, 'retail', p.retail_price) order by p.name)
      from public.products p join public.inventory_balances b on b.product_id = p.id
      join private.inventory_valuation v on v.product_id = p.id), '[]'::jsonb),
    'customers', coalesce((select jsonb_agg(to_jsonb(c) order by c.name)
      from public.customer_ledger() c), '[]'::jsonb)
  ) into v;
  return v;
end $$;

-- =====================================================================
-- Grants
-- =====================================================================
revoke execute on function internal.require_can_sell(), internal.bulk_new_price(numeric, text, numeric, integer)
  from public, anon, authenticated;
revoke execute on function
  public.owner_save_expense(uuid, date, text, numeric, text, text, boolean),
  public.owner_list_expenses(date, date),
  public.day_cash_summary(date),
  public.close_day(date, numeric, numeric, numeric, text, text),
  public.owner_list_day_closings(integer),
  public.owner_dead_stock(integer),
  public.owner_daily_report(date, date),
  public.owner_bulk_price_preview(uuid[], text, text, numeric, integer),
  public.owner_bulk_price_apply(uuid[], text, text, numeric, integer, text),
  public.owner_reorder_suggestions(integer, integer),
  public.owner_export(date, date)
  from public, anon;
grant execute on function
  public.owner_save_expense(uuid, date, text, numeric, text, text, boolean),
  public.owner_list_expenses(date, date),
  public.day_cash_summary(date),
  public.close_day(date, numeric, numeric, numeric, text, text),
  public.owner_list_day_closings(integer),
  public.owner_dead_stock(integer),
  public.owner_daily_report(date, date),
  public.owner_bulk_price_preview(uuid[], text, text, numeric, integer),
  public.owner_bulk_price_apply(uuid[], text, text, numeric, integer, text),
  public.owner_reorder_suggestions(integer, integer),
  public.owner_export(date, date)
  to authenticated;
