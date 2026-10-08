-- Stage 3 tests: sales, negotiated final amount, examples A/B/D, permissions,
-- void, product delete and activity history. Runs after 10_stage1_stage2_test.sql.
\set ON_ERROR_STOP 1
\set QUIET 1

select test.login(test.uuid('owner'), test.uuid('s_owner'));
reset role;
update internal.private_unlocks set expires_at = now() + interval '1 hour' where session_id = test.uuid('s_owner');
set role authenticated;

-- Fresh products for clean numbers
insert into public.products (code, name, wholesale_price, retail_price) values ('EXA-CABLE', 'Example A cable', 350, 400);
insert into public.products (code, name, wholesale_price, retail_price) values ('EXB-CHG', 'Example B charger', 700, 700);
insert into public.products (code, name, wholesale_price, retail_price) values ('EXD-BUDS', 'Example D buds', 1700, 1700);
select test.set('pa', (select id::text from public.products where code = 'EXA-CABLE'));
select test.set('pb', (select id::text from public.products where code = 'EXB-CHG'));
select test.set('pd', (select id::text from public.products where code = 'EXD-BUDS'));

-- Example A purchase: 100 @ 200
select public.owner_post_purchase(public.owner_save_purchase_draft(jsonb_build_object('supplier_id', test.get('sup'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.get('pa'), 'quantity', 100, 'unit_price', 200))))::uuid,
  'cash', 20000, gen_random_uuid());
-- Example B purchases: 10 @ 500 then 50 @ 550
select public.owner_post_purchase(public.owner_save_purchase_draft(jsonb_build_object('supplier_id', test.get('sup'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.get('pb'), 'quantity', 10, 'unit_price', 500))))::uuid,
  'cash', 5000, gen_random_uuid());
select public.owner_post_purchase(public.owner_save_purchase_draft(jsonb_build_object('supplier_id', test.get('sup'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.get('pb'), 'quantity', 50, 'unit_price', 550))))::uuid,
  'cash', 27500, gen_random_uuid());
select public.owner_post_purchase(public.owner_save_purchase_draft(jsonb_build_object('supplier_id', test.get('sup'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.get('pd'), 'quantity', 10, 'unit_price', 1000))))::uuid,
  'cash', 10000, gen_random_uuid());

-- Example A sale: 30 wholesale @ 350, fully paid 10,500
select test.set('k_a', gen_random_uuid()::text);
select test.set('sale_a', (public.complete_sale(jsonb_build_object(
  'sale_type', 'wholesale', 'customer_name', 'Ali Mobile Shop', 'payment_method', 'cash', 'amount_tendered', 10500,
  'items', jsonb_build_array(jsonb_build_object('product_id', test.get('pa'), 'quantity', 30))), test.uuid('k_a')) ->> 'id'));
select test.assert((select total = 10500 and discount_amount = 0 and invoice_no like 'INV-%' from public.sales where id = test.uuid('sale_a')),
  'Example A: sale total Rs. 10,500');
select test.assert((select count(*) = 1 and sum(quantity) = 30 and min(cost_price) = 200
                      from public.sale_items i
                      join private.sale_item_costs c on c.sale_item_id = i.id
                     where i.sale_id = test.uuid('sale_a')),
  'sale item cost snapshot links every sold unit to its consumed batch');
select test.assert((select (public.owner_sale_profit(test.uuid('sale_a')) ->> 'cost')::numeric = 6000
                       and (public.owner_sale_profit(test.uuid('sale_a')) ->> 'profit')::numeric = 4500),
  'Example A: COGS Rs. 6,000, gross profit Rs. 4,500');
select test.assert((select b.saleable_qty = 70 and v.carrying_value = 14000
                      from public.inventory_balances b join private.inventory_valuation v using (product_id)
                     where product_id = test.uuid('pa')), 'Example A: stock 70 worth Rs. 14,000');
select test.assert((select customer_id is not null from public.sales where id = test.uuid('sale_a')),
  'new shopkeeper saved automatically for wholesale');
select test.assert((public.complete_sale('{}'::jsonb, test.uuid('k_a')) ->> 'already_posted')::boolean,
  'AC-08 retrying a completed sale does not post twice');
select test.assert((select saleable_qty = 70 from public.inventory_balances where product_id = test.uuid('pa')),
  'retry did not reduce stock again');

-- Example B: sell 15; FIFO consumes 10 @ 500 then 5 @ 550.
select test.set('sale_b', (public.complete_sale(jsonb_build_object(
  'sale_type', 'retail', 'payment_method', 'jazzcash',
  'items', jsonb_build_array(jsonb_build_object('product_id', test.get('pb'), 'quantity', 15))), gen_random_uuid()) ->> 'id'));
select test.assert((select (public.owner_sale_profit(test.uuid('sale_b')) ->> 'net_sales')::numeric = 10500
                       and (public.owner_sale_profit(test.uuid('sale_b')) ->> 'cost')::numeric = 7750
                       and (public.owner_sale_profit(test.uuid('sale_b')) ->> 'profit')::numeric = 2750),
  'Example B: FIFO COGS is 10 @ 500 plus 5 @ 550');
select test.assert((select b.saleable_qty = 45 and v.carrying_value = 24750
                      from public.inventory_balances b join private.inventory_valuation v using (product_id)
                     where product_id = test.uuid('pb')), 'Example B: 45 units remain in the newer batch');
select test.assert((select array_agg(c.quantity order by b.posted_at, b.id) = array[10, 5]
                       and array_agg(c.cost_price order by b.posted_at, b.id) = array[500, 550]::numeric[]
                      from public.sale_items i
                      join private.sale_item_costs c on c.sale_item_id = i.id
                      join private.batches b on b.id = c.batch_id
                     where i.sale_id = test.uuid('sale_b')),
  'sale item cost rows preserve FIFO batch quantities and unit costs');
select test.set('pb_later_purchase', public.owner_save_purchase_draft(jsonb_build_object(
  'supplier_id', test.get('sup'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.get('pb'), 'quantity', 1, 'unit_price', 1000))))::text);
select public.owner_post_purchase(test.uuid('pb_later_purchase'), 'cash', 1000, gen_random_uuid());
select test.assert((public.owner_sale_profit(test.uuid('sale_b')) ->> 'cost')::numeric = 7750
                    and (public.owner_sale_profit(test.uuid('sale_b')) ->> 'profit')::numeric = 2750,
  'later product cost changes do not alter the earlier sale profit snapshot');
select test.assert((select remaining_quantity = 46 and stock_value = 25750
                      from public.owner_fifo_stock_values()
                     where product_id = test.uuid('pb')),
  'stock value is based on remaining FIFO batch quantities and costs');
select test.assert((select count(*) = 2 and sum(remaining_quantity) = 46
                      from public.owner_product_batches(test.uuid('pb'))),
  'owner batch detail lists remaining batches for the product');
select test.assert((public.owner_profit_summary((now() at time zone 'Asia/Karachi')::date,
                                                 (now() at time zone 'Asia/Karachi')::date) ->> 'cogs')::numeric = 13750,
  'profit summary uses per-batch snapshots for completed sales');
select test.expect_error(format($$select public.complete_sale(jsonb_build_object('sale_type','retail','payment_method','cash',
  'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 7))), gen_random_uuid())$$,
  test.get('pb')), 'INSUFFICIENT_STOCK', 'sale exceeding remaining batch stock is blocked');
select test.assert((select saleable_qty = 6 from public.inventory_balances where product_id = test.uuid('pb')),
  'blocked sale does not change stock');
select test.expect_error(format($$select public.complete_sale(jsonb_build_object('sale_type','retail','payment_method','jazzcash',
  'amount_tendered', 500, 'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1))), gen_random_uuid())$$,
  test.get('pb')), 'exact amount', 'electronic payment must be the exact amount');

-- Example D: bill 3400, tendered 2000 → shortfall, nothing posted; 3500 cash → change 100
select test.expect_error(format($$select public.complete_sale(jsonb_build_object('sale_type','retail','payment_method','cash',
  'amount_tendered', 2000, 'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 2))), gen_random_uuid())$$,
  test.get('pd')), 'SHORTFALL.*1,400', 'Example D: Rs. 1,400 shortfall blocks the sale');
select test.assert((select saleable_qty = 10 from public.inventory_balances where product_id = test.uuid('pd')),
  'Example D: stock unchanged after blocked sale');
select test.assert((public.complete_sale(jsonb_build_object('sale_type','retail','payment_method','cash',
  'amount_tendered', 3500, 'items', jsonb_build_array(jsonb_build_object('product_id', test.get('pd'), 'quantity', 2))),
  gen_random_uuid()) ->> 'change')::numeric = 100, 'Example D: Rs. 3,500 cash → change Rs. 100');

-- Negotiated final amount: bill 10,050 → shopkeeper pays 10,000
-- 25 cables @ 350 = 8750 + 1 buds @ 1300 (owner price) = 10,050
select test.expect_error(format($$select public.complete_sale(jsonb_build_object('sale_type','wholesale','customer_name','Bilal Traders',
  'payment_method','cash','final_amount',10000,
  'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 25),
                             jsonb_build_object('product_id', %L, 'quantity', 1, 'unit_price', 1300))), gen_random_uuid())$$,
  test.get('pa'), test.get('pd')), 'reason', 'discount / round-off needs a reason');
select test.set('sale_n', (public.complete_sale(jsonb_build_object('sale_type','wholesale','customer_name','Bilal Traders',
  'payment_method','cash','final_amount',10000,'discount_reason','Round off','amount_tendered',10000,
  'items', jsonb_build_array(jsonb_build_object('product_id', test.get('pa'), 'quantity', 25),
                             jsonb_build_object('product_id', test.get('pd'), 'quantity', 1, 'unit_price', 1300))),
  gen_random_uuid()) ->> 'id'));
select test.assert((select subtotal = 10050 and discount_amount = 50 and total = 10000 and discount_reason = 'Round off'
                      from public.sales where id = test.uuid('sale_n')), 'bill 10,050 paid 10,000 → discount 50 recorded with reason');
select test.assert((select sum(discount_share) = 50 and sum(net_total) = 10000 from public.sale_items where sale_id = test.uuid('sale_n')),
  'discount spread over lines; line net totals add up to 10,000');
select test.assert((select (public.owner_sale_profit(test.uuid('sale_n')) ->> 'profit')::numeric = 10000 - (25 * 200 + 1000)),
  'profit uses the received 10,000 (not 10,050)');
select test.expect_error(format($$select public.complete_sale(jsonb_build_object('sale_type','retail','payment_method','cash',
  'final_amount', 5000, 'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1))), gen_random_uuid())$$,
  test.get('pd')), 'cannot be more', 'final amount cannot exceed the bill');

-- Below cost needs owner confirmation
select test.expect_error(format($$select public.complete_sale(jsonb_build_object('sale_type','retail','payment_method','cash',
  'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1, 'unit_price', 500))), gen_random_uuid())$$,
  test.get('pd')), 'BELOW_COST', 'below-cost sale needs owner confirmation');
select test.expect_error(format($$select public.complete_sale(jsonb_build_object('sale_type','retail','payment_method','cash',
  'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1, 'unit_price', 0))), gen_random_uuid())$$,
  test.get('pd')), 'greater than zero', 'zero sale price rejected');

-- Not enough stock
select test.expect_error(format($$select public.complete_sale(jsonb_build_object('sale_type','retail','payment_method','cash',
  'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 999))), gen_random_uuid())$$,
  test.get('pd')), 'INSUFFICIENT_STOCK', 'cannot sell more than available stock');

-- Void restores stock and value
select test.set('pd_before', (select v.carrying_value::text from private.inventory_valuation v where product_id = test.uuid('pd')));
select public.owner_void_sale(test.uuid('sale_n'), 'Customer cancelled');
select test.assert((select status = 'voided' from public.sales where id = test.uuid('sale_n')), 'sale voided');
select test.assert((select saleable_qty = 70 from public.inventory_balances where product_id = test.uuid('pa')),
  'void returned the 25 cables');
select test.assert((select remaining_quantity = 70
                      from private.batches
                     where product_id = test.uuid('pa') and source_type = 'purchase'),
  'void restores quantity to the exact FIFO batch consumed by the sale');
select public.owner_void_sale(test.uuid('sale_n'), 'Customer cancelled again');
select test.assert((select saleable_qty = 70 from public.inventory_balances where product_id = test.uuid('pa')),
  'repeated void does not restore the same FIFO quantity twice');
select test.assert((select bool_and(ok) from public.owner_reconcile_inventory()), 'ledger still reconciles after sales and void');
select test.assert((public.sales_summary((now() at time zone 'Asia/Karachi')::date, (now() at time zone 'Asia/Karachi')::date) ->> 'net_sales')::numeric
  = 10500 + 10500 + 3400, 'sales summary excludes voided sales');

-- Product delete: unused product can be deleted; used product cannot
insert into public.products (code, name) values ('TMP-DEL', 'Mistake product');
select test.set('pdel', (select id::text from public.products where code = 'TMP-DEL'));
select test.expect_error(format($$select public.owner_delete_product(%L, '')$$, test.get('pdel')), 'reason', 'delete needs a reason');
select public.owner_delete_product(test.uuid('pdel'), 'Added by mistake');
select test.assert(not exists (select 1 from public.products where code = 'TMP-DEL'), 'unused product deleted');
select test.expect_error(format($$select public.owner_delete_product(%L, 'test')$$, test.get('pa')), 'PRODUCT_IN_USE',
  'product with sales/stock history cannot be deleted');
select test.assert((select count(*) >= 1 from public.owner_activity_log(50) where action = 'product_deleted'
                      and actor_name = 'Owner' and reason = 'Added by mistake'), 'history shows who deleted which product and why');
select test.assert((select count(*) >= 3 from public.owner_activity_log(100) where action = 'sale_completed'),
  'history shows completed sales');
reset role;

-- Partner permissions
update public.profiles set is_active = true, can_create_sale = false, can_override_price = false,
  sessions_valid_after = now() - interval '1 hour' where id = test.uuid('partner');
select test.login(test.uuid('partner'), gen_random_uuid());
set role authenticated;
select test.expect_error(format($$select public.complete_sale(jsonb_build_object('sale_type','retail','payment_method','cash',
  'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1))), gen_random_uuid())$$, test.get('pb')),
  'permission', 'partner without permission cannot sell');
select test.assert((select count(*) >= 3 from public.sales), 'partner can view sales list');
select test.assert((select count(*) = 0 from private.sale_costs), 'partner cannot see sale costs');
select test.assert((select count(*) = 0 from private.sale_item_costs), 'partner cannot see FIFO batch cost rows');
select test.expect_error(format($$select public.owner_sale_profit(%L)$$, test.get('sale_a')), 'Owner access', 'partner cannot see profit');
select test.expect_error($$select * from public.owner_activity_log()$$, 'Owner access', 'partner cannot see history');
reset role;
update public.profiles set can_create_sale = true where id = test.uuid('partner');
set role authenticated;
select test.assert((public.complete_sale(jsonb_build_object('sale_type','retail','payment_method','cash',
  'items', jsonb_build_array(jsonb_build_object('product_id', test.get('pb'), 'quantity', 1))), gen_random_uuid()) ->> 'invoice_no') like 'INV-%',
  'partner with permission can sell at default price');
select test.expect_error(format($$select public.complete_sale(jsonb_build_object('sale_type','retail','payment_method','cash',
  'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1, 'unit_price', 390))), gen_random_uuid())$$, test.get('pb')),
  'not allowed to change', 'partner cannot change prices without permission');
select test.expect_error(format($$select public.complete_sale(jsonb_build_object('sale_type','retail','payment_method','cash',
  'final_amount', 390, 'discount_reason', 'x', 'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1))), gen_random_uuid())$$, test.get('pb')),
  'not allowed to give discounts', 'partner cannot give discount without permission');
select test.expect_error(format($$select public.owner_void_sale(%L, 'x')$$, test.get('sale_a')), 'Owner access', 'partner cannot void');
select test.expect_error(format($$select public.owner_delete_product(%L, 'x')$$, test.get('pb')), 'Owner access', 'partner cannot delete products');
reset role;
select test.assert((select count(*) >= 1 from private.audit_logs where action = 'sale_completed' and actor_id = test.uuid('partner')),
  'partner''s sale is recorded under the partner''s name');

\echo 'ALL STAGE 3 DATABASE TESTS PASSED'
