-- Rehearsal of the production cutover. Run after:
--   replica_schema.sql, seed_prod_like.sql, 01_migration.sql, 02_cutover_corrections.sql
\set ON_ERROR_STOP on
\set QUIET on
\pset tuples_only on

create or replace function _expect_error(p_sql text, p_like text) returns text
language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm ilike p_like then return 'ok: ' || sqlerrm; end if;
    raise exception 'wrong error. expected like [%], got [%]', p_like, sqlerrm;
  end;
  raise exception 'expected an error like [%] but statement succeeded: %', p_like, p_sql;
end $$;
grant execute on function _expect_error(text, text) to authenticated;

create or replace function _held(p_company text, p_rep text, p_item text) returns int language sql as $$
  select coalesce((select rl.qty_units_held from rep_ledger rl
                   join sales_reps r on r.id = rl.rep_id join items i on i.id = rl.item_id
                   join companies c on c.id = rl.company_id
                   where c.name = p_company and r.name = p_rep and i.name = p_item), 0)
$$;
create or replace function _stock(p_item text) returns int language sql as $$
  select coalesce((select s.qty_units from stock_ledger s join items i on i.id = s.item_id where i.name = p_item), 0)
$$;

\echo 'C1. after the cutover every balance reconciles'
do $$ begin
  if exists (select 1 from cutover_differences()) then raise exception 'differences remain'; end if;
  if exists (select 1 from v_reconciliation where stock_variance <> 0 or rep_variance <> 0) then raise exception 'view shows variance'; end if;
end $$;

\echo 'C2. no rep balance was changed by the cutover'
do $$ begin
  if exists (select 1 from _before_rep b join rep_ledger r using (company_id, rep_id, item_id)
             where r.qty_units_held <> b.qty_units_held)
     or (select count(*) from _before_rep) <> (select count(*) from rep_ledger) then
    raise exception 'a rep balance changed';
  end if;
  if exists (select 1 from audit_log where table_name in ('rep_ledger', 'stock_ledger')) then
    raise exception 'a ledger correction was logged';
  end if;
end $$;

\echo 'C3. no warehouse balance was changed'
do $$ begin
  if exists (select 1 from _before_stock b join stock_ledger s using (company_id, item_id) where s.qty_units <> b.qty_units) then
    raise exception 'warehouse changed';
  end if;
end $$;

\echo 'C4. all 25 gaps are recorded as opening differences, balances as before'
do $$ declare n int; begin
  if _held('NO 07','KIR','CHIT CHAT 15/=') <> 12672 or _held('Unilever','Saji','L.BOY 160/=') <> 735
     or _held('Unilever','Roy','SUNSILK 80ML 340/= BLACK') <> 0 or _held('NO 07','NIRO','SAPTHAMI BEEDI') <> 100
     or _held('Unilever','NIRO','L.BOY 160/=') <> 1029 or _held('NO 07','THAYA','CHIT CHAT 15/=') <> 10368
     or _stock('AMRITHA 110/=') <> 576 or _stock('SIGNAL 120G 240/=') <> 288 or _stock('SAPTHAMI BEEDI') <> 100 then
    raise exception 'a kept balance moved';
  end if;
  select count(*) into n from opening_balances;
  if n <> 25 then raise exception 'expected 25 opening rows, got %', n; end if;
  if (select count(*) from opening_balances where reason like 'Reversed issue:%') <> 16 then raise exception 'reversed-issue rows'; end if;
  if (select sum(units) from opening_balances o join items i on i.id = o.item_id where i.name = 'AMRITHA 110/=') <> -235 then raise exception 'AMRITHA opening'; end if;
  if (select units from v_opening_balances where rep_name = 'KIR') <> 6336 then raise exception 'KIR opening'; end if;
  if (select units from v_opening_balances where rep_name = 'Roy') <> 48 then raise exception 'Roy opening'; end if;
  if (select units from v_opening_balances where rep_name = 'NIRO' and item_name = 'L.BOY 160/=') <> 294 then raise exception 'NIRO opening'; end if;
end $$;

\echo 'C5. running 02 again changes nothing'
create temp table _snap as
  select 's' k, item_id a, 0 b, qty_units v from stock_ledger
  union all select 'r', rep_id, item_id, qty_units_held from rep_ledger
  union all select 'o', item_id, coalesce(rep_id, 0), units from opening_balances;
\i 02_cutover_corrections.sql
do $$ begin
  if exists (
    (select * from _snap except
     select * from (select 's' k, item_id a, 0 b, qty_units v from stock_ledger
                    union all select 'r', rep_id, item_id, qty_units_held from rep_ledger
                    union all select 'o', item_id, coalesce(rep_id, 0), units from opening_balances) x)
  ) then raise exception 're-run changed data'; end if;
  if (select count(*) from opening_balances) <> 25 then raise exception 're-run duplicated opening rows'; end if;
end $$;

\echo 'C6. a balance can still be corrected later, one row or the reversed issues in bulk'
do $$ declare t text; n int; begin
  delete from opening_balances where reason like 'Reversed issue:%';
  n := cutover_fix_reversed_issues();
  if n <> 16 then raise exception 'expected 16 bulk corrections, got %', n; end if;
  if _held('Unilever','NIRO','L.BOY 160/=') <> 735 or _held('Unilever','NIRO','SUNSILK 80ML 340/= BLACK') <> 96
     or _held('Unilever','NIRO','SUNLIGHT LIQUIT 700/=') <> 15 or _held('NO 07','THAYA','CHIT CHAT 15/=') <> 9792
     or _held('NO 07','THAYA','BUBLEEGUM 5/=') <> 150 then
    raise exception 'reversed issues not corrected';
  end if;
  if (select count(*) from audit_log where table_name = 'rep_ledger' and new_data->>'reason' like 'Cutover:%') <> 16 then
    raise exception 'bulk correction not audited';
  end if;

  t := cutover_resolve('NO 07', 'CHIT CHAT 15/=', 'KIR', 'use_documents', 'Owner confirmed: the 11 returned cases count against the 22 issued.');
  if _held('NO 07','KIR','CHIT CHAT 15/=') <> 6336 then raise exception 'KIR not switched: %', t; end if;
  if exists (select 1 from v_opening_balances where rep_name = 'KIR') then raise exception 'KIR opening row left behind'; end if;

  perform cutover_resolve('NO 07', 'SAPTHAMI BEEDI', null,    'use_documents', 'Owner confirmed 30 units per case.');
  perform cutover_resolve('NO 07', 'SAPTHAMI BEEDI', 'NIRO',  'use_documents', 'Owner confirmed 30 units per case.');
  perform cutover_resolve('NO 07', 'SAPTHAMI BEEDI', 'THAYA', 'use_documents', 'Owner confirmed 30 units per case.');
  if _stock('SAPTHAMI BEEDI') <> 30 or _held('NO 07','NIRO','SAPTHAMI BEEDI') <> 30 or _held('NO 07','THAYA','SAPTHAMI BEEDI') <> 30 then
    raise exception 'SAPTHAMI not switched';
  end if;

  perform cutover_resolve('NO 07', 'AMRITHA 110/=', null, 'use_documents', 'Shelf count matched the documents.');
  if _stock('AMRITHA 110/=') <> 811 then raise exception 'AMRITHA not switched'; end if;
  -- and back again
  perform cutover_resolve('NO 07', 'AMRITHA 110/=', null, 'keep_ledger', 'Recount: shelf matches the balance.');
  if _stock('AMRITHA 110/=') <> 811 or exists (select 1 from v_opening_balances where item_name = 'AMRITHA 110/=') then
    raise exception 'already balanced: keep_ledger must be a no-op';
  end if;

  if exists (select 1 from cutover_differences()) then raise exception 'differences after switching'; end if;
  if (select count(*) from opening_balances) <> 4 then raise exception 'opening rows after switching: %', (select count(*) from opening_balances); end if;
end $$;

\echo 'C7. guard rails'
select _expect_error($q$select cutover_resolve('Unilever','SUNSILK 80ML 340/= BLACK','Roy','use_documents','x')$q$, '%cannot be below zero%');
select _expect_error($q$select cutover_resolve('Unilever','NO SUCH ITEM',null,'keep_ledger','x')$q$, '%0 matches%');
select _expect_error($q$select cutover_resolve('Unilever','L.BOY 160/=','NOBODY','keep_ledger','x')$q$, '%0 matches%');
select _expect_error($q$select cutover_resolve('Unilever','L.BOY 160/=','Saji','delete_it','x')$q$, '%Action must be%');
select _expect_error($q$select cutover_resolve('Unilever','L.BOY 160/=','Saji','keep_ledger','  ')$q$, '%reason is required%');
do $$ begin
  -- Roy's failed use_documents must not have dropped his opening row
  if (select units from v_opening_balances where rep_name = 'Roy') <> 48 then raise exception 'failed call lost data'; end if;
end $$;

\echo 'C8. the cutover tools cannot be called through the API, even by an admin'
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
set role authenticated;
select _expect_error($q$select cutover_resolve('Unilever','L.BOY 160/=','Saji','use_documents','x')$q$, '%permission denied%');
select _expect_error($q$select cutover_fix_reversed_issues()$q$, '%permission denied%');
select _expect_error($q$select * from cutover_differences()$q$, '%permission denied%');
select _expect_error($q$insert into opening_balances (company_id, item_id, units, reason) values (1, 1, 5, 'x')$q$, '%permission denied%');

\echo 'C9. normal work after the cutover stays balanced, including on corrected rows'
do $$ declare d text; uni int; no7 int; niro int; roy int; begin
  select id into uni from companies where name = 'Unilever';
  select id into no7 from companies where name = 'NO 07';
  select id into niro from sales_reps where company_id = uni and name = 'NIRO';
  select id into roy  from sales_reps where company_id = uni and name = 'Roy';

  -- NIRO returns 1 case of L.BOY, then is settled for the rest
  perform post_transaction(uni, 'RET', current_date, niro, null,
    jsonb_build_array(jsonb_build_object('item_id', (select id from items where name = 'L.BOY 160/='), 'qty_cases', 1, 'qty_units', 0)));
  perform post_transaction(uni, 'SALE', current_date, niro, 'Settlement',
    (select jsonb_agg(jsonb_build_object('item_id', item_id, 'qty_cases', 0, 'qty_units', qty_units_held))
     from rep_ledger where rep_id = niro and qty_units_held > 0));
  if (select coalesce(sum(qty_units_held), 0) from rep_ledger where rep_id = niro) <> 0 then raise exception 'NIRO not settled'; end if;
  if (select sold_units from v_rep_summary where rep_id = niro) <> 15 + 96 + 1224 + 144 + 144 + 588 + 44 + 128 + 48 + 96 + 48 then
    raise exception 'NIRO was settled for the wrong quantity: %', (select sold_units from v_rep_summary where rep_id = niro);
  end if;

  -- The return that had no issue behind it can still be reversed cleanly
  perform reverse_transaction('RET-260822-001', 'entered under the wrong rep');
  if _held('Unilever','Roy','SUNSILK 80ML 340/= BLACK') <> 48 then raise exception 'reverse of legacy return'; end if;

  -- A legacy item still posts at its current pack size
  d := post_transaction(no7, 'GRN', current_date, null, null,
    jsonb_build_array(jsonb_build_object('item_id', (select id from items where name = 'SAPTHAMI BEEDI'), 'qty_cases', 2, 'qty_units', 0)));
  if (select total_units from tx_lines where doc_no = d) <> 60 then raise exception 'pack size'; end if;
end $$;
reset role;
do $$ begin
  if exists (select 1 from cutover_differences()) then raise exception 'differences after normal work'; end if;
end $$;

\echo 'CUTOVER REHEARSAL PASSED'
