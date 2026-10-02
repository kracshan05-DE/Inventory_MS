-- Behaviour tests for 01_migration.sql. Run after replica + seed + migration.
-- Every block raises on failure; psql stops at the first one.
\set ON_ERROR_STOP on
\set QUIET on
\pset tuples_only on

-- Helpers: act as a signed-in user / as nobody.
create or replace function _as(p_uid text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_uid, false);
$$;
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
grant execute on function _as(text), _expect_error(text, text) to authenticated, anon;

\echo '1. existing balances and documents are untouched by the migration'
do $$ begin
  if exists (select 1 from _before_stock b join stock_ledger s using (company_id, item_id) where s.qty_units <> b.qty_units)
     or (select count(*) from _before_stock) <> (select count(*) from stock_ledger) then
    raise exception 'stock_ledger changed';
  end if;
  if exists (select 1 from _before_rep b join rep_ledger r using (company_id, rep_id, item_id) where r.qty_units_held <> b.qty_units_held) then
    raise exception 'rep_ledger changed';
  end if;
  if exists (select 1 from _before_docs b join tx_header h using (doc_no) where h.type <> b.type or h.status <> b.status)
     or (select count(*) from _before_docs) <> (select count(*) from tx_header) then
    raise exception 'documents changed';
  end if;
  if exists (select 1 from tx_lines where total_units is null or units_per_case is null) then
    raise exception 'backfill incomplete';
  end if;
end $$;

\echo '2. legacy data reconciles in the new view (reversed + REV excluded, AJUST signed)'
select _as('aaaaaaaa-0000-0000-0000-000000000001');
set role authenticated;
do $$ declare r record; begin
  for r in select * from v_reconciliation loop
    if r.stock_variance <> 0 or r.rep_variance <> 0 then
      raise exception 'variance on %: stock %, rep %', r.item_name, r.stock_variance, r.rep_variance;
    end if;
  end loop;
  if (select count(*) from v_reconciliation) <> 4 then raise exception 'admin should see all 4 items'; end if;
  if (select adjust_units from v_reconciliation where item_id = 2) <> -7 then raise exception 'adjust sign'; end if;
  if (select issued_units from v_reconciliation where item_id = 1) <> 96 then raise exception 'reversed ISS not excluded'; end if;
end $$;

\echo '3. GRN: number continues after existing docs for that day, stock goes up'
do $$ declare d text; begin
  d := post_transaction(1, 'GRN', '2026-09-01', null, ' first new grn ',
        '[{"item_id":1,"qty_cases":1,"qty_units":2,"free_units":1,"disc_pct":5,"disc_amt":10}]');
  if d <> 'GRN-260901-003' then raise exception 'doc no %', d; end if;
  if (select qty_units from stock_ledger where item_id = 1) <> 409 + 51 then raise exception 'stock'; end if;
  if (select total_units from tx_lines where doc_no = d) <> 51 then raise exception 'total units'; end if;
  if (select remarks from tx_header where doc_no = d) <> 'first new grn' then raise exception 'remarks trim'; end if;
  if (select line_value from v_tx_lines where doc_no = d) <> round(51 * 145.45 * 0.95 - 10, 2) then raise exception 'line value'; end if;
end $$;

\echo '4. ISSUE more than stock is rejected and leaves nothing behind'
select _expect_error(
  $q$select post_transaction(1,'ISS',current_date,1,null,'[{"item_id":2,"qty_cases":0,"qty_units":10},{"item_id":1,"qty_cases":100,"qty_units":0}]')$q$,
  'Not enough stock for "COMFORT 160/="%');
do $$ begin
  if (select qty_units from stock_ledger where item_id = 2) <> 271 then raise exception 'partial post leaked'; end if;
  if exists (select 1 from tx_header where type = 'ISS' and date = current_date) then raise exception 'orphan header'; end if;
end $$;

\echo '5. ISSUE moves stock from warehouse to rep'
do $$ declare d text; begin
  d := post_transaction(1, 'ISS', '2026-09-10', 2, null, '[{"item_id":1,"qty_cases":2,"qty_units":4}]');
  if (select qty_units from stock_ledger where item_id = 1) <> 460 - 100 then raise exception 'stock'; end if;
  if (select qty_units_held from rep_ledger where rep_id = 2 and item_id = 1) <> 100 then raise exception 'rep'; end if;
end $$;

\echo '6. RETURN more than the rep holds is rejected'
select _expect_error(
  $q$select post_transaction(1,'RET','2026-09-11',2,null,'[{"item_id":1,"qty_cases":0,"qty_units":101}]')$q$,
  'Kumar holds only 100 units%');

\echo '7. RETURN then SALE (settlement) clears the rep, both checks still balance'
do $$ declare d text; r record; begin
  perform post_transaction(1, 'RET', '2026-09-11', 2, null, '[{"item_id":1,"qty_cases":0,"qty_units":30}]');
  d := post_transaction(1, 'SALE', '2026-09-11', 2, 'settled', '[{"item_id":1,"qty_cases":0,"qty_units":70}]');
  if d not like 'SAL-260911-%' then raise exception 'prefix %', d; end if;
  if (select qty_units_held from rep_ledger where rep_id = 2 and item_id = 1) <> 0 then raise exception 'rep not cleared'; end if;
  if (select qty_units from stock_ledger where item_id = 1) <> 390 then raise exception 'sale must not touch warehouse'; end if;
  select * into r from v_reconciliation where item_id = 1;
  if r.stock_variance <> 0 or r.rep_variance <> 0 or r.sold_units <> 70 then raise exception 'recon after sale'; end if;
  select * into r from v_rep_summary where rep_id = 2;
  if r.sold_units <> 70 or r.held_units <> 0 or r.issued_units <> 100 then raise exception 'rep summary'; end if;
end $$;

\echo '8. input validation'
select _expect_error($q$select post_transaction(1,'GRN',current_date + 1,null,null,'[{"item_id":1,"qty_cases":1}]')$q$, '%future%');
select _expect_error($q$select post_transaction(1,'GRN',current_date,null,null,'[{"item_id":1,"qty_cases":1},{"item_id":1,"qty_units":1}]')$q$, '%appears twice%');
select _expect_error($q$select post_transaction(1,'GRN',current_date,null,null,'[]')$q$, '%at least one%');
select _expect_error($q$select post_transaction(1,'GRN',current_date,null,null,'[{"item_id":1,"qty_cases":0,"qty_units":0}]')$q$, '%is zero%');
select _expect_error($q$select post_transaction(1,'GRN',current_date,null,null,'[{"item_id":1,"qty_cases":-1}]')$q$, '%cannot be negative%');
select _expect_error($q$select post_transaction(1,'GRN',current_date,null,null,'[{"item_id":3,"qty_cases":1}]')$q$, '%do not belong%');
select _expect_error($q$select post_transaction(1,'ISS',current_date,null,null,'[{"item_id":1,"qty_cases":1}]')$q$, '%Select a sales rep%');
select _expect_error($q$select post_transaction(1,'ISS',current_date,3,null,'[{"item_id":1,"qty_cases":1}]')$q$, '%does not belong%');
select _expect_error($q$select post_transaction(1,'XXX',current_date,null,null,'[{"item_id":1,"qty_cases":1}]')$q$, '%Unknown transaction type%');
select _expect_error($q$select post_transaction(1,'REV',current_date,null,null,'[{"item_id":1,"qty_cases":1}]')$q$, '%Unknown transaction type%');
select _expect_error($q$select post_transaction(1,'GRN',current_date,null,null,'[{"item_id":1,"qty_units":1,"disc_pct":150}]')$q$, '%Discount%');
select _expect_error($q$select post_transaction(1,'GRN',current_date,null,null,'[{"item_id":1,"qty_units":1,"disc_amt":99999}]')$q$, '%larger than the line value%');
select _expect_error($q$select post_transaction(1,'AJUST',current_date,null,null,'[{"item_id":1,"qty_units":-1}]')$q$, '%needs a reason%');
select _expect_error($q$select post_transaction(1,'AJUST',current_date,null,'x','[{"item_id":1,"qty_cases":1,"qty_units":-1}]')$q$, '%same sign%');
select _expect_error($q$select post_transaction(1,'AJUST',current_date,null,'x','[{"item_id":4,"qty_units":-1}]')$q$, 'Not enough stock%');

\echo '9. ADJUSTMENT (admin): signed, moves warehouse only'
do $$ declare d text; begin
  d := post_transaction(1, 'AJUST', '2026-09-12', null, 'count correction', '[{"item_id":2,"qty_cases":-1,"qty_units":-3}]');
  if d not like 'ADJ-260912-%' then raise exception 'prefix %', d; end if;
  if (select qty_units from stock_ledger where item_id = 2) <> 271 - 75 then raise exception 'adjust stock'; end if;
  if (select stock_variance from v_reconciliation where item_id = 2) <> 0 then raise exception 'recon after adjust'; end if;
end $$;

\echo '10. REVERSAL: restores balances, links both documents, cannot repeat'
do $$ declare d text; v text; begin
  d := post_transaction(1, 'ISS', '2026-09-13', 1, null, '[{"item_id":2,"qty_cases":1,"qty_units":0}]');
  if (select qty_units from stock_ledger where item_id = 2) <> 196 - 72 then raise exception 'pre'; end if;
  v := reverse_transaction(d, 'wrong rep');
  if (select qty_units from stock_ledger where item_id = 2) <> 196 then raise exception 'stock not restored'; end if;
  if (select qty_units_held from rep_ledger where rep_id = 1 and item_id = 2) <> 82 then raise exception 'rep not restored'; end if;
  if (select status || '/' || reversed_by from tx_header where doc_no = d) <> 'reversed/' || v then raise exception 'orig link'; end if;
  if (select type || '/' || reversal_of from tx_header where doc_no = v) <> 'REV/' || d then raise exception 'rev link'; end if;
  if (select count(*) from tx_lines where doc_no = v) <> 1 then raise exception 'rev lines'; end if;
  perform _expect_error(format('select reverse_transaction(%L, %L)', d, 'again'), '%already reversed%');
  perform _expect_error(format('select reverse_transaction(%L, %L)', v, 'undo'), '%cannot be reversed%');
  perform _expect_error($q$select reverse_transaction('GRN-260901-003', '')$q$, '%reason%');
  perform _expect_error($q$select reverse_transaction('NOPE-1', 'x')$q$, '%not found%');
  if exists (select 1 from v_reconciliation where stock_variance <> 0 or rep_variance <> 0) then raise exception 'recon after reversal'; end if;
end $$;

\echo '11. REVERSAL of a GRN whose stock has already gone out is rejected'
select _expect_error($q$select reverse_transaction('GRN-260901-001', 'test')$q$, 'Not enough stock%');

\echo '12. REVERSAL of a legacy document and of a SALE work'
do $$ declare v text; begin
  v := reverse_transaction('RET-260903-001', 'legacy fix');   -- Saji gets 20 units back
  if (select qty_units_held from rep_ledger where rep_id = 1 and item_id = 1) <> 96 then raise exception 'legacy reversal rep'; end if;
  v := reverse_transaction((select doc_no from tx_header where type = 'SALE' limit 1), 'not sold');
  if (select qty_units_held from rep_ledger where rep_id = 2 and item_id = 1) <> 70 then raise exception 'sale reversal'; end if;
  if exists (select 1 from v_reconciliation where stock_variance <> 0 or rep_variance <> 0) then raise exception 'recon'; end if;
end $$;

\echo '13. history is locked: changing units per case or price does not rewrite old documents'
do $$ declare before_units int; before_val numeric; before_stock int; begin
  select sum(total_units), sum(gross_value) into before_units, before_val from v_tx_lines where item_id = 1;
  select qty_units into before_stock from stock_ledger where item_id = 1;
  update items set units_per_case = 24, unit_price = 160 where id = 1;
  if (select sum(total_units) from v_tx_lines where item_id = 1) <> before_units then raise exception 'units rewritten'; end if;
  if (select sum(gross_value) from v_tx_lines where item_id = 1) <> before_val then raise exception 'value rewritten'; end if;
  if (select qty_units from stock_ledger where item_id = 1) <> before_stock then raise exception 'stock changed'; end if;
  if (select stock_value from stock_ledger where item_id = 1) <> before_stock * 160 then raise exception 'stock_value not refreshed'; end if;
  if (select stock_variance from v_reconciliation where item_id = 1) <> 0 then raise exception 'recon after upc change'; end if;
  -- a new document uses the new values
  perform post_transaction(1, 'GRN', '2026-09-14', null, null, '[{"item_id":1,"qty_cases":1}]');
  if (select total_units from tx_lines l join tx_header h using (doc_no) where h.date = '2026-09-14' and l.item_id = 1) <> 24 then raise exception 'new upc not used'; end if;
end $$;

\echo '14. master data guards + audit trail'
select _expect_error($q$update items set company_id = 3 where id = 1$q$, '%cannot be moved%');
select _expect_error($q$update items set units_per_case = 0 where id = 1$q$, '%items_units_per_case_check%');
select _expect_error($q$update user_profiles set role = 'user' where id = 'aaaaaaaa-0000-0000-0000-000000000002'; update user_profiles set role = 'user' where id = 'aaaaaaaa-0000-0000-0000-000000000001'$q$, '%At least one admin%');
do $$ declare a record; begin
  select * into a from audit_log where table_name = 'items' and record_id = '1' order by id desc limit 1;
  if a.action <> 'UPDATE' or a.old_data->>'units_per_case' <> '48' or a.new_data->>'units_per_case' <> '24'
     or a.user_id <> 'aaaaaaaa-0000-0000-0000-000000000001' or a.company_id <> 1 then
    raise exception 'item audit row wrong: %', row_to_json(a);
  end if;
  if not exists (select 1 from audit_log where table_name = 'tx_header' and action = 'UPDATE' and new_data->>'status' = 'reversed') then
    raise exception 'reversal not audited';
  end if;
end $$;

\echo '15. admin cannot bypass the functions by writing tables directly'
select _expect_error($q$insert into tx_header (doc_no, company_id, date, type) values ('HACK-1', 1, current_date, 'GRN')$q$, '%permission denied%');
select _expect_error($q$update stock_ledger set qty_units = 999999$q$, '%permission denied%');
select _expect_error($q$update rep_ledger set qty_units_held = 0$q$, '%permission denied%');
select _expect_error($q$delete from tx_lines$q$, '%permission denied%');
select _expect_error($q$delete from audit_log$q$, '%permission denied%');
select _expect_error($q$select next_doc_no('GRN', current_date)$q$, '%permission denied%');
select _expect_error($q$select apply_movement(1, 1, null, 1000, 0)$q$, '%permission denied%');
do $$ declare n int; begin
  delete from items where id = 4; get diagnostics n = row_count;
  if n <> 0 then raise exception 'items delete should affect 0 rows'; end if;
end $$;

-- ---- a normal user, limited to HEMAS (company 3) ---------------------------
reset role;
insert into auth.users (id, email, raw_user_meta_data)
values ('bbbbbbbb-0000-0000-0000-000000000001', 'clerk@example.com', '{"full_name":"Clerk"}');

\echo '16. a new user has no access until an admin grants it'
select _as('bbbbbbbb-0000-0000-0000-000000000001');
set role authenticated;
do $$ begin
  if (select role from user_profiles where id = 'bbbbbbbb-0000-0000-0000-000000000001') <> 'user' then raise exception 'default role'; end if;
  if (select count(*) from companies) <> 0 or (select count(*) from items) <> 0
     or (select count(*) from tx_header) <> 0 or (select count(*) from v_stock) <> 0 then
    raise exception 'new user can see data';
  end if;
end $$;
select _expect_error($q$select post_transaction(3,'GRN',current_date,null,null,'[{"item_id":3,"qty_cases":1}]')$q$, '%do not have access%');
select _expect_error($q$insert into user_company_access (user_id, company_id) values ('bbbbbbbb-0000-0000-0000-000000000001', 1)$q$, '%row-level security%');

select _as('aaaaaaaa-0000-0000-0000-000000000001');
insert into user_company_access (user_id, company_id) values ('bbbbbbbb-0000-0000-0000-000000000001', 3);

\echo '17. user sees and posts only in the granted company; cannot escalate'
select _as('bbbbbbbb-0000-0000-0000-000000000001');
do $$ declare d text; n int; begin
  if (select array_agg(id order by id) from companies) <> array[3] then raise exception 'companies visible'; end if;
  if (select count(*) from items where company_id <> 3) <> 0 then raise exception 'other items visible'; end if;
  if (select count(*) from v_reconciliation) <> 1 then raise exception 'recon scope'; end if;
  if (select count(*) from v_tx_documents where company_id <> 3) <> 0 then raise exception 'docs scope'; end if;
  if (select count(*) from v_tx_lines where company_id <> 3) <> 0 then raise exception 'lines scope'; end if;
  if (select count(*) from tx_lines l join items i on i.id = l.item_id where i.company_id <> 3) <> 0 then raise exception 'raw lines scope'; end if;
  if (select count(*) from v_financial_summary) <> 1 then raise exception 'legacy view leaks'; end if;
  if (select count(*) from audit_log) <> 0 then raise exception 'audit visible to user'; end if;

  d := post_transaction(3, 'ISS', '2026-09-15', 3, null, '[{"item_id":3,"qty_cases":1,"qty_units":0}]');
  if (select qty_units from v_stock where item_id = 3) <> 36 then raise exception 'user post'; end if;

  update user_profiles set role = 'admin' where id = auth.uid(); get diagnostics n = row_count;
  if n <> 0 then raise exception 'self-promotion possible'; end if;
  update items set unit_price = 1 where id = 3; get diagnostics n = row_count;
  if n <> 0 then raise exception 'user edited an item'; end if;

  perform _expect_error($q$select post_transaction(1,'GRN',current_date,null,null,'[{"item_id":1,"qty_cases":1}]')$q$, '%do not have access%');
  perform _expect_error($q$select post_transaction(3,'AJUST',current_date,null,'x','[{"item_id":3,"qty_units":1}]')$q$, '%Only an admin%');
  perform _expect_error(format('select reverse_transaction(%L, %L)', d, 'x'), '%Only an admin%');
  perform _expect_error($q$select reverse_transaction('GRN-260901-001', 'x')$q$, '%not found%');
  perform _expect_error($q$insert into items (company_id, name) values (3, 'X')$q$, '%row-level security%');
  perform _expect_error($q$insert into companies (name) values ('X')$q$, '%row-level security%');
  if (select count(*) from tx_summary(1)) <> 1 or (select doc_count from tx_summary(1)) <> 0 then raise exception 'tx_summary leaks'; end if;
  if (select doc_count from tx_summary(3)) <> 2 then raise exception 'tx_summary own company'; end if;
end $$;

\echo '18. not signed in: nothing readable, nothing callable'
reset role;
select _as('');
set role anon;
select _expect_error($q$select * from companies$q$, '%permission denied%');
select _expect_error($q$select * from v_stock$q$, '%permission denied%');
select _expect_error($q$select * from v_financial_summary$q$, '%permission denied%');
select _expect_error($q$select * from v_stock_summary$q$, '%permission denied%');
select _expect_error($q$select post_transaction(1,'GRN',current_date,null,null,'[{"item_id":1,"qty_cases":1}]')$q$, '%permission denied%');
select _expect_error($q$select accessible_company_ids()$q$, '%permission denied%');
reset role;

\echo '19. tx_summary totals and item filter'
select _as('aaaaaaaa-0000-0000-0000-000000000001');
set role authenticated;
do $$ declare s record; begin
  select * into s from tx_summary(1, '2026-09-01', '2026-09-01');
  -- GRN-260901-001: 485*145.45*0.98 + (360*82.5 - 100) ; GRN-260901-003: 51*145.45*0.95 - 10
  if s.doc_count <> 2 or s.grn_value <> round(485*145.45*0.98, 2) + (360*82.5 - 100) + round(51*145.45*0.95 - 10, 2) then
    raise exception 'summary %', row_to_json(s);
  end if;
  if (select doc_count from tx_summary(1, null, null, null, null, 2)) <> (select count(*) from v_tx_documents where company_id = 1 and item_ids @> array[2]) then
    raise exception 'item filter';
  end if;
  if (select doc_count from tx_summary(1, null, null, 'ISS', null, null, null, 'reversed')) <> 2 then raise exception 'status filter'; end if;
end $$;
reset role;

\echo 'ALL TESTS PASSED'
