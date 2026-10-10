-- =====================================================================
-- Sales & profit for ANY period: today, 7/30 days, a year, all time
-- (since the app started) or custom dates. Adds pieces sold, month-by-month
-- and product-wise profit (owner, private area unlocked).
-- =====================================================================

-- Summary now also returns pieces sold.
create or replace function public.sales_summary(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform internal.require_active();
  with s as (
    select id, total, discount_amount, sale_type from public.sales
     where status = 'completed'
       and (completed_at at time zone 'Asia/Karachi')::date between p_from and p_to
  )
  select jsonb_build_object(
           'count', (select count(*) from s),
           'pieces', coalesce((select sum(i.quantity) from public.sale_items i where i.sale_id in (select id from s)), 0),
           'net_sales', coalesce((select sum(total) from s), 0),
           'discounts', coalesce((select sum(discount_amount) from s), 0),
           'wholesale', coalesce((select sum(total) from s where sale_type = 'wholesale'), 0),
           'retail', coalesce((select sum(total) from s where sale_type = 'retail'), 0))
    into v;
  return v;
end $$;

-- Date of the very first sale (start of "All time" and the year list).
create or replace function public.sales_first_date()
returns date language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_active();
  return (select min((completed_at at time zone 'Asia/Karachi')::date) from public.sales where status = 'completed');
end $$;

-- Month by month: bills, pieces, sales, cost, profit.
create or replace function public.owner_profit_by_month(p_from date, p_to date)
returns table (month date, bills bigint, pieces bigint, net_sales numeric, cogs numeric, profit numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    with s as (
      select id, total, date_trunc('month', completed_at at time zone 'Asia/Karachi')::date as m
        from public.sales
       where status = 'completed'
         and (completed_at at time zone 'Asia/Karachi')::date between p_from and p_to
    )
    select s.m, count(*)::bigint,
           coalesce(sum((select sum(i.quantity) from public.sale_items i where i.sale_id = s.id)), 0)::bigint,
           sum(s.total),
           round(coalesce(sum((select sum(c.cost_total) from private.sale_costs c where c.sale_id = s.id)), 0), 2),
           sum(s.total) - round(coalesce(sum((select sum(c.cost_total) from private.sale_costs c where c.sale_id = s.id)), 0), 2)
      from s
     group by s.m
     order by s.m desc;
end $$;

-- Product-wise: how many pieces of each product were sold and the profit.
-- Line amount is after the bill discount share (money really received).
create or replace function public.owner_profit_by_product(p_from date, p_to date)
returns table (product_id uuid, code text, name text, pieces bigint, net_sales numeric, cogs numeric, profit numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select i.product_id, max(i.product_code), max(i.product_name),
           sum(i.quantity)::bigint,
           sum(i.net_total),
           round(coalesce(sum(c.cost_total), 0), 2),
           sum(i.net_total) - round(coalesce(sum(c.cost_total), 0), 2)
      from public.sale_items i
      join public.sales s on s.id = i.sale_id
      left join private.sale_costs c on c.sale_item_id = i.id
     where s.status = 'completed'
       and (s.completed_at at time zone 'Asia/Karachi')::date between p_from and p_to
     group by i.product_id
     order by 7 desc, 4 desc
     limit 1000;
end $$;

revoke execute on function public.sales_first_date(), public.owner_profit_by_month(date, date),
  public.owner_profit_by_product(date, date) from public, anon;
grant execute on function public.sales_first_date(), public.owner_profit_by_month(date, date),
  public.owner_profit_by_product(date, date) to authenticated;
