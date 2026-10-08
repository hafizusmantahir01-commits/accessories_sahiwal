-- Stage 1 + 2 database acceptance tests (run on a throw-away database).
-- Covers AC-01, AC-02, AC-03, AC-04, AC-05, AC-08 (posting side), AC-12 (cost
-- snapshots for purchases), example B (opening + purchase averaging) and the
-- purchase half of example A.
\set ON_ERROR_STOP 1
\set QUIET 1

create schema test;
grant usage on schema test to authenticated, anon;
create table test.vars (k text primary key, v text);
grant select, insert, update on test.vars to authenticated;

create function test.set(k text, v text) returns void language sql as
$$ insert into test.vars values (k, v) on conflict (k) do update set v = excluded.v $$;
create function test.get(k text) returns text language sql stable as $$ select v from test.vars where vars.k = get.k $$;
create function test.uuid(k text) returns uuid language sql stable as $$ select test.get(k)::uuid $$;

create function test.assert(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'ASSERTION FAILED: %', msg; end if;
  raise notice 'ok - %', msg;
end $$;

create function test.expect_error(stmt text, pattern text, msg text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    if sqlerrm ~* pattern then raise notice 'ok - % (error: %)', msg, sqlerrm; return; end if;
    raise exception 'ASSERTION FAILED: % — wrong error: %', msg, sqlerrm;
  end;
  raise exception 'ASSERTION FAILED: % — expected an error matching "%"', msg, pattern;
end $$;

-- Sign in as a user: sub, session id and original sign-in time (amr).
create function test.login(p_user uuid, p_session uuid, p_auth_time timestamptz default now()) returns void
language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object(
    'sub', p_user, 'role', 'authenticated', 'session_id', p_session,
    'iat', extract(epoch from now())::bigint,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password',
            'timestamp', extract(epoch from p_auth_time)::bigint)))::text, false)
$$;
grant execute on all functions in schema test to authenticated, anon;

-- ------------------------------------------------------------------
-- Setup (as postgres / service role): owner and partner accounts
-- ------------------------------------------------------------------
insert into auth.users (email, raw_user_meta_data) values
  ('owner@test.local', '{"full_name":"Owner"}'), ('partner@test.local', '{"full_name":"Partner"}');
select test.set('owner', (select id::text from auth.users where email = 'owner@test.local'));
select test.set('partner', (select id::text from auth.users where email = 'partner@test.local'));
select test.set('s_owner', gen_random_uuid()::text);
select test.set('s_owner2', gen_random_uuid()::text);
select test.set('s_partner', gen_random_uuid()::text);

select test.assert((select not is_active and role = 'partner' from public.profiles where id = test.uuid('partner')),
  'AC-01 new auth users get an INACTIVE partner profile (no self-registration)');
select internal.bootstrap_owner('owner@test.local', 'Owner');
select test.expect_error($$select internal.bootstrap_owner('partner@test.local')$$, 'already exists',
  'only one owner can be bootstrapped');

-- Inactive partner cannot read anything
select test.login(test.uuid('partner'), test.uuid('s_partner'));
set role authenticated;
select test.expect_error($$select * from public.stock_list()$$, 'Not authorised', 'inactive partner blocked');
select test.assert((select count(*) = 0 from public.business_settings), 'inactive partner sees no settings');
reset role;

-- ------------------------------------------------------------------
-- Owner: private area secret + unlock (AC-03)
-- ------------------------------------------------------------------
select test.login(test.uuid('owner'), test.uuid('s_owner'));
set role authenticated;
select test.assert((public.private_status() ->> 'has_secret')::boolean = false, 'no private password yet');
select test.expect_error($$select public.unlock_private('x')$$, 'PRIVATE_SECRET_NOT_SET', 'unlock needs a secret');
select public.set_private_secret(null, 'OwnerSecret#1');
select test.expect_error($$select public.set_private_secret(null, 'Another#Secret')$$, 'incorrect',
  'changing the secret requires the current one');
select test.assert((public.unlock_private('wrong') ->> 'unlocked')::boolean = false, 'wrong secret does not unlock');
select test.expect_error($$select * from public.owner_stock_valuation()$$, 'PRIVATE_LOCKED', 'owner still locked');
select test.assert((public.unlock_private('OwnerSecret#1') ->> 'unlocked')::boolean, 'correct secret unlocks');
select test.assert((public.private_status() ->> 'unlocked')::boolean, 'status shows unlocked');

-- Owner activates partner with read-only defaults
select public.owner_set_user_access(test.uuid('partner'), true, false, false);
select test.expect_error(format($$select public.owner_set_user_access(%L, false, false, false)$$, test.uuid('owner')),
  'cannot be changed', 'owner cannot deactivate themself');
reset role;

-- ------------------------------------------------------------------
-- Products (AC-04)
-- ------------------------------------------------------------------
set role authenticated;
insert into public.categories (name) values ('Cables');
select test.set('cat', (select id::text from public.categories where name = 'Cables'));
insert into public.products (code, name, category_id, wholesale_price, retail_price)
  values ('', 'USB-C Cable 1m', test.uuid('cat'), 300, 350);
select test.assert((select code = 'AS-0001' from public.products where name = 'USB-C Cable 1m'), 'blank code auto-generates AS-0001');
select test.set('cable', (select id::text from public.products where code = 'AS-0001'));
select test.expect_error($$insert into public.products (code, name) values (' as-0001 ', 'dup')$$, 'products_code_uq',
  'duplicate code rejected case-insensitively after trimming');
insert into public.products (code, name, wholesale_price, retail_price) values (' chg-20w ', '20W Charger', 380, 450);
select test.set('charger', (select id::text from public.products where code = 'CHG-20W'));
select test.assert(test.get('charger') is not null, 'code normalised to upper case and trimmed');
insert into public.products (code, name, wholesale_price, retail_price) values ('', 'Earbuds', 900, 1200);
select test.set('buds', (select id::text from public.products where name = 'Earbuds'));
select test.assert((select count(*) = 3 from public.inventory_balances where saleable_qty = 0),
  'creating a product does not add stock');
select test.assert((select l.name = '20W Charger' and l.retail_price = 450 and l.saleable_qty = 0
                      from public.lookup_product('chg-20w') l), 'code lookup returns product, price and stock');

-- ------------------------------------------------------------------
-- Opening stock + purchase: example B (AC-05, AC-08)
-- ------------------------------------------------------------------
select test.set('k_open', gen_random_uuid()::text);
select test.set('open1', public.owner_post_opening_stock(test.uuid('charger'), 10, 200, test.uuid('k_open'), 'shelf count')::text);
select test.assert(public.owner_post_opening_stock(test.uuid('charger'), 10, 200, test.uuid('k_open'))::text = test.get('open1'),
  'AC-08 opening stock retry with same key returns the same entry');
select test.assert((select saleable_qty = 10 from public.inventory_balances where product_id = test.uuid('charger')),
  'AC-08 retry did not double the stock');
select test.assert((select count(*) = 0 from private.payments), 'opening stock creates no payment/expense');

insert into private.suppliers (name, phone) values ('Hall Road Traders', '');
select test.set('sup', (select id::text from private.suppliers limit 1));
select test.set('pur1', public.owner_save_purchase_draft(jsonb_build_object(
  'supplier_id', test.get('sup'), 'supplier_ref', 'INV-77',
  'items', jsonb_build_array(jsonb_build_object('product_id', test.get('charger'), 'quantity', 10, 'unit_price', 300))))::text);
select test.assert((select saleable_qty = 10 from public.inventory_balances where product_id = test.uuid('charger')),
  'AC-08 draft purchase leaves stock unchanged');
select test.assert((select count(*) = 0 from private.batches where purchase_id = test.uuid('pur1')),
  'draft purchase creates no stock batches');
select test.expect_error(format($$select public.owner_post_purchase(%L, 'cash', 2999, %L)$$, test.get('pur1'), gen_random_uuid()),
  'SHORTFALL', 'underpaid purchase cannot be posted');
select test.expect_error(format($$select public.owner_post_purchase(%L, 'cash', 3500, %L)$$, test.get('pur1'), gen_random_uuid()),
  'more than the purchase total', 'overpaid purchase rejected (enter exact amount)');
select test.set('k_pur1', gen_random_uuid()::text);
select test.assert((public.owner_post_purchase(test.uuid('pur1'), 'bank_transfer', 3000, test.uuid('k_pur1')) ->> 'purchase_no') = 'PUR-000001',
  'purchase posted with number PUR-000001');
select test.assert((public.owner_post_purchase(test.uuid('pur1'), 'bank_transfer', 3000, test.uuid('k_pur1')) ->> 'already_posted')::boolean,
  'AC-08 retrying the post is a no-op');
select test.assert((select count(*) = 1 and bool_and(quantity = 10 and remaining_quantity = 10 and unit_cost = 300)
                      from private.batches where purchase_id = test.uuid('pur1')),
  'purchase posting creates one available batch with the purchase unit cost');
select test.assert((select b.posted_at = p.posted_at
                      from private.batches b join private.purchases p on p.id = b.purchase_id
                     where b.purchase_id = test.uuid('pur1')),
  'batch and purchase share the actual posting timestamp');
select test.assert((select b.saleable_qty = 20 and v.average_cost = 250 and v.carrying_value = 4000 + 1000
                      from public.inventory_balances b join private.inventory_valuation v using (product_id)
                     where product_id = test.uuid('charger')),
  'Example B: 10@200 opening + 10@300 purchase → qty 20, average Rs. 250, value Rs. 5,000');
select test.assert((select count(*) = 1 and sum(amount) = 3000 from private.payments where source_type = 'purchase'),
  'exactly one Rs. 3,000 purchase payment recorded');
select test.expect_error(format($$select public.owner_save_purchase_draft(jsonb_build_object('id', %L, 'supplier_id', %L,
  'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1, 'unit_price', 1))))$$,
  test.get('pur1'), test.get('sup'), test.get('charger')), 'cannot be edited', 'posted purchase is immutable');
select test.assert((select count(*) = 1 from public.owner_find_duplicate_supplier_ref(test.uuid('sup'), 'inv-77')),
  'duplicate supplier bill reference is detected');

-- Example A (purchase side): 100 cables @ Rs. 200 fully paid
select test.set('pur2', public.owner_save_purchase_draft(jsonb_build_object('supplier_id', test.get('sup'),
  'items', jsonb_build_array(jsonb_build_object('product_id', test.get('cable'), 'quantity', 100, 'unit_price', 200))))::text);
select public.owner_post_purchase(test.uuid('pur2'), 'cash', 20000, gen_random_uuid());
select test.assert((select b.saleable_qty = 100 and v.carrying_value = 20000 and v.average_cost = 200
                      from public.inventory_balances b join private.inventory_valuation v using (product_id)
                     where product_id = test.uuid('cable')), 'Example A: 100 cables, stock cost Rs. 20,000');

-- Landed-cost allocation with rounding remainder (value-based)
select test.set('pur3', public.owner_save_purchase_draft(jsonb_build_object('supplier_id', test.get('sup'),
  'extra_costs', 100, 'extra_costs_note', 'transport',
  'items', jsonb_build_array(
     jsonb_build_object('product_id', test.get('buds'), 'quantity', 3, 'unit_price', 100),
     jsonb_build_object('product_id', test.get('cable'), 'quantity', 3, 'unit_price', 100),
     jsonb_build_object('product_id', test.get('charger'), 'quantity', 3, 'unit_price', 100, 'line_discount', 0))))::text);
select test.assert((select array_agg(allocated_extra order by line_no) = array[33.34, 33.33, 33.33]::numeric[]
                      from private.purchase_items where purchase_id = test.uuid('pur3')),
  'extra cost Rs. 100 split 33.34/33.33/33.33 (rounding remainder to first largest line)');
select test.assert((select total = 1000 from private.purchases where id = test.uuid('pur3')), 'purchase total includes extra costs');
-- Quantity-based fallback when all line values are zero (free goods)
select test.set('pur4', public.owner_save_purchase_draft(jsonb_build_object('supplier_id', test.get('sup'),
  'extra_costs', 10,
  'items', jsonb_build_array(
     jsonb_build_object('product_id', test.get('buds'), 'quantity', 1, 'unit_price', 0),
     jsonb_build_object('product_id', test.get('cable'), 'quantity', 3, 'unit_price', 0))))::text);
select test.assert((select array_agg(allocated_extra order by line_no) = array[2.50, 7.50]::numeric[]
                      from private.purchase_items where purchase_id = test.uuid('pur4')),
  'zero-value lines allocate extra cost by quantity');
select public.owner_delete_purchase_draft(test.uuid('pur4'));
select test.expect_error(format($$select public.owner_save_purchase_draft(jsonb_build_object('supplier_id', %L,
  'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 2, 'unit_price', 10, 'line_discount', 25))))$$,
  test.get('sup'), test.get('buds')), 'discount cannot exceed', 'over-discount rejected');
select test.expect_error(format($$select public.owner_save_purchase_draft(jsonb_build_object('supplier_id', %L,
  'items', jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1.5, 'unit_price', 10))))$$,
  test.get('sup'), test.get('buds')), 'whole number', 'fractional quantity rejected');

-- Post pur3 and check that the earlier purchase lines keep their original costs (AC-12 for purchases)
select public.owner_post_purchase(test.uuid('pur3'), 'cash', 1000, gen_random_uuid());
select test.assert((select count(*) = 3 and sum(quantity) = 9
                      from private.batches where purchase_id = test.uuid('pur3')),
  'purchase posting creates exactly one batch for every purchase line');
select test.assert((select unit_cost = 111.113333
                      from private.batches
                     where purchase_id = test.uuid('pur3')
                       and product_id = test.uuid('buds')),
  'batch unit cost adds allocated extra cost per unit at six-decimal precision');
-- The allocated extra cost is added to each unit, not merely stored at line level.
select test.set('pur5', public.owner_save_purchase_draft(jsonb_build_object(
  'supplier_id', test.get('sup'), 'extra_costs', 1000,
  'items', jsonb_build_array(jsonb_build_object('product_id', test.get('cable'), 'quantity', 100, 'unit_price', 200))))::text);
select public.owner_post_purchase(test.uuid('pur5'), 'cash', 21000, gen_random_uuid());
select test.assert((select unit_cost = 210 and quantity = 100 and remaining_quantity = 100
                      from private.batches where purchase_id = test.uuid('pur5')),
  '100 units and Rs. 1,000 extra cost increases batch unit cost by Rs. 10');
select test.assert((select landed_unit_cost = 300 from private.purchase_items where purchase_id = test.uuid('pur1')),
  'original purchase batch cost history preserved');
select test.assert((select bool_and(ok) from public.owner_reconcile_inventory()), 'balances reconcile with the movement ledger');
reset role;

-- ------------------------------------------------------------------
-- Partner privacy (AC-02)
-- ------------------------------------------------------------------
select test.login(test.uuid('partner'), test.uuid('s_partner'));
set role authenticated;
select test.assert((select count(*) = 3 from public.products), 'partner can view products');
select test.assert((select count(*) = 3 from public.stock_list()), 'partner can view stock list');
select test.assert((select saleable_qty = 23 from public.lookup_product('CHG-20W')), 'partner lookup shows stock');
select test.assert((select count(*) > 0 from public.stock_movement_history(test.uuid('charger'))), 'partner sees safe movement history');
select test.assert((select count(*) = 0 from private.inventory_valuation), 'partner gets NO rows from valuation table');
select test.assert((select count(*) = 0 from private.stock_movements), 'partner gets NO rows from cost ledger');
select test.assert((select count(*) = 0 from private.batches), 'partner gets NO purchase batch costs');
select test.assert((select count(*) = 0 from private.purchases), 'partner gets NO purchases');
select test.assert((select count(*) = 0 from private.suppliers), 'partner gets NO suppliers');
select test.assert((select count(*) = 0 from private.payments), 'partner gets NO payments');
select test.assert((select count(*) = 0 from private.audit_logs), 'partner gets NO audit log');
select test.expect_error($$select * from public.owner_stock_valuation()$$, 'Owner access required', 'partner blocked from valuation RPC');
select test.expect_error($$select public.owner_product_cost(test.uuid('charger'))$$, 'Owner access required', 'partner blocked from cost RPC');
select test.expect_error($$select * from public.owner_list_purchases()$$, 'Owner access required', 'partner blocked from purchases RPC');
select test.expect_error($$select public.unlock_private('OwnerSecret#1')$$, 'Owner access required', 'partner cannot unlock private area even with the password');
select test.expect_error($$insert into public.products (code, name) values ('X1', 'x')$$, 'row-level security', 'partner cannot add products');
select test.expect_error($$insert into private.suppliers (name) values ('x')$$, 'row-level security', 'partner cannot add suppliers');
select test.expect_error($$update public.inventory_balances set saleable_qty = 999$$, 'permission denied', 'partner cannot edit stock directly');
select test.expect_error($$select internal.receive_stock(test.uuid('charger'), 5, 0, 'adjustment_in', 'x', null)$$,
  'permission denied', 'partner cannot call internal posting functions');
select test.expect_error($$select * from internal.private_secret$$, 'permission denied', 'partner cannot read secret hash');
update public.products set retail_price = 1 where code = 'CHG-20W';
select test.assert((select retail_price = 450 from public.products where code = 'CHG-20W'), 'partner price change silently affects 0 rows (RLS)');
update public.profiles set can_override_price = true, can_create_sale = true where id = auth.uid();
reset role;
select test.assert((select not can_override_price and not can_create_sale from public.profiles where id = test.uuid('partner')),
  'partner cannot grant themself permissions');
set role authenticated;
select test.assert((select count(*) = 1 from public.profiles), 'partner sees only own profile');
select test.assert(not exists (select 1 from information_schema.columns
                                where table_schema = 'public' and table_name in ('products', 'inventory_balances', 'categories', 'product_images')
                                  and column_name ~ 'cost|value|profit'), 'no cost/value columns on partner-readable tables');
reset role;

-- ------------------------------------------------------------------
-- Private area expiry, other sessions, lockout (AC-03)
-- ------------------------------------------------------------------
select test.login(test.uuid('owner'), test.uuid('s_owner2'));
set role authenticated;
select test.expect_error($$select * from public.owner_stock_valuation()$$, 'PRIVATE_LOCKED', 'unlock does not carry over to another owner session');
reset role;
update internal.private_unlocks set expires_at = now() - interval '1 second' where session_id = test.uuid('s_owner');
select test.login(test.uuid('owner'), test.uuid('s_owner'));
set role authenticated;
select test.expect_error($$select * from public.owner_stock_valuation()$$, 'PRIVATE_LOCKED', 'private area locks after inactivity expiry');
select test.assert((select count(*) = 0 from private.purchases), 'expired unlock: private tables return nothing');
select test.assert((public.touch_private() ->> 'unlocked')::boolean = false, 'touch cannot revive an expired unlock');
select public.unlock_private('OwnerSecret#1');
select public.lock_private();
select test.expect_error($$select * from public.owner_stock_valuation()$$, 'PRIVATE_LOCKED', 'lock_private (logout) locks immediately');
select public.unlock_private('bad1'); select public.unlock_private('bad2'); select public.unlock_private('bad3');
select public.unlock_private('bad4'); select public.unlock_private('bad5');
select test.expect_error($$select public.unlock_private('OwnerSecret#1')$$, 'Too many attempts', 'throttled after 5 failed unlock attempts');
reset role;
delete from internal.unlock_attempts;

-- ------------------------------------------------------------------
-- Session revocation & deactivation (AC-01)
-- ------------------------------------------------------------------
select test.login(test.uuid('owner'), test.uuid('s_owner'));
set role authenticated;
select public.unlock_private('OwnerSecret#1');
select public.owner_revoke_sessions(test.uuid('partner'));
reset role;
select test.login(test.uuid('partner'), test.uuid('s_partner'), now() - interval '1 minute');
set role authenticated;
select test.expect_error($$select * from public.stock_list()$$, 'Not authorised', 'revoked partner session (even after token refresh) is blocked');
reset role;
select test.login(test.uuid('partner'), gen_random_uuid(), now() + interval '1 second');
set role authenticated;
select test.assert((select count(*) = 3 from public.stock_list()), 'partner can sign in again after revocation');
reset role;
select test.login(test.uuid('owner'), test.uuid('s_owner'));
set role authenticated;
select public.owner_set_user_access(test.uuid('partner'), false, false, false);
reset role;
select test.login(test.uuid('partner'), gen_random_uuid(), now() + interval '2 seconds');
set role authenticated;
select test.expect_error($$select * from public.lookup_product('AS-0001')$$, 'Not authorised', 'deactivated partner is blocked');
reset role;

-- ------------------------------------------------------------------
-- Opening stock closes once trading starts
-- ------------------------------------------------------------------
select test.login(test.uuid('owner'), test.uuid('s_owner'));
set role authenticated;
select public.owner_start_trading();
select test.expect_error(format($$select public.owner_post_opening_stock(%L, 1, 10, %L)$$, test.get('buds'), gen_random_uuid()),
  'Trading has started', 'opening stock blocked after trading starts');
select test.assert((select count(*) >= 5 from private.audit_logs), 'audit trail recorded');
reset role;
select test.assert(not has_function_privilege('anon', 'public.stock_list(text, uuid, boolean, boolean)', 'execute'), 'anon cannot call RPCs');
select test.assert(not has_table_privilege('anon', 'public.products', 'select'), 'anon cannot read products');

\echo 'ALL STAGE 1 + 2 DATABASE TESTS PASSED'
