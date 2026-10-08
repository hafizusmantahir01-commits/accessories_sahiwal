-- Use per-batch sale snapshots for COGS, with the immutable legacy snapshot
-- as a fallback for sales posted before FIFO was introduced.
create or replace function public.owner_sale_profit(p_sale_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform internal.require_owner_unlocked();
  with item_costs as (
    select i.id, i.sale_id,
           coalesce(
             (select sum(sc.quantity * sc.cost_price)
                from private.sale_item_costs sc
               where sc.sale_item_id = i.id),
             legacy.cost_total,
             0
           ) as cogs
      from public.sale_items i
      left join private.sale_costs legacy on legacy.sale_item_id = i.id
     where i.sale_id = p_sale_id
  )
  select jsonb_build_object(
           'net_sales', s.total,
           'cost', round(coalesce(sum(ic.cogs), 0), 2),
           'profit', s.total - round(coalesce(sum(ic.cogs), 0), 2),
           'discount', s.discount_amount)
    into v
    from public.sales s
    left join item_costs ic on ic.sale_id = s.id
   where s.id = p_sale_id
   group by s.id, s.total, s.discount_amount;
  return v;
end $$;

create or replace function public.owner_profit_summary(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  perform internal.require_owner_unlocked();
  with sales_in_period as (
    select id, total from public.sales
     where status = 'completed'
       and (completed_at at time zone 'Asia/Karachi')::date between p_from and p_to
  ), item_costs as (
    select i.sale_id,
           coalesce(
             (select sum(sc.quantity * sc.cost_price)
                from private.sale_item_costs sc
               where sc.sale_item_id = i.id),
             legacy.cost_total,
             0
           ) as cogs
      from public.sale_items i
      join sales_in_period s on s.id = i.sale_id
      left join private.sale_costs legacy on legacy.sale_item_id = i.id
  ), costs as (
    select round(coalesce(sum(cogs), 0), 2) as cogs from item_costs
  )
  select jsonb_build_object(
           'net_sales', coalesce((select sum(total) from sales_in_period), 0),
           'cogs', (select cogs from costs),
           'gross_profit', coalesce((select sum(total) from sales_in_period), 0) - (select cogs from costs))
    into v;
  return v;
end $$;

-- Cost-bearing stock information remains owner-only and requires the private
-- area to be unlocked; partners continue using the existing safe stock_list.
create or replace function public.owner_fifo_stock_values(p_search text default null)
returns table (product_id uuid, remaining_quantity bigint, stock_value numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select p.id,
           coalesce(sum(b.remaining_quantity), 0)::bigint,
           coalesce(sum(b.remaining_quantity * b.unit_cost), 0)::numeric
      from public.products p
      left join private.batches b on b.product_id = p.id and b.remaining_quantity > 0
     where p.is_active
       and (p_search is null or btrim(p_search) = ''
            or p.code ilike '%' || btrim(p_search) || '%'
            or p.name ilike '%' || btrim(p_search) || '%'
            or p.brand ilike '%' || btrim(p_search) || '%'
            or p.model ilike '%' || btrim(p_search) || '%')
     group by p.id
     order by p.name;
end $$;

create or replace function public.owner_product_batches(p_product_id uuid)
returns table (id uuid, product_id uuid, purchase_id uuid, quantity integer,
               remaining_quantity integer, unit_cost numeric, posted_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform internal.require_owner_unlocked();
  return query
    select b.id, b.product_id, b.purchase_id, b.quantity, b.remaining_quantity,
           b.unit_cost, b.posted_at
      from private.batches b
     where b.product_id = p_product_id and b.remaining_quantity > 0
     order by b.posted_at, b.id;
end $$;

revoke execute on function public.owner_sale_profit(uuid),
  public.owner_profit_summary(date, date),
  public.owner_fifo_stock_values(text),
  public.owner_product_batches(uuid) from public, anon;
grant execute on function public.owner_sale_profit(uuid),
  public.owner_profit_summary(date, date),
  public.owner_fifo_stock_values(text),
  public.owner_product_batches(uuid) to authenticated;
