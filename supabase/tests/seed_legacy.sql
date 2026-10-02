-- Legacy-style data, written the way the OLD pages wrote it:
-- header insert, then line inserts, with the old trigger moving stock.
\set ON_ERROR_STOP on

insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'uncle@example.com',  '{"full_name":"Uncle"}'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'rakka@example.com',  '{"full_name":"Rakka"}');

insert into companies (id, name) values (1,'Unilever'), (2,'NO 07'), (3,'HEMAS');
select setval('companies_id_seq', 3);

update user_profiles set role = 'admin', company_id = 1 where id = 'aaaaaaaa-0000-0000-0000-000000000001';
update user_profiles set role = 'admin', company_id = 3 where id = 'aaaaaaaa-0000-0000-0000-000000000002';

insert into items (id, company_id, name, units_per_case, unit_price) values
  (1, 1, 'COMFORT 160/=',  48, 145.45),
  (2, 1, 'SUNLIGHT 90/=',  72,  82.50),
  (3, 3, 'CLOGARD 120G',   12, 200.00),
  (4, 1, 'NEVER RECEIVED', 24,  50.00);
select setval('items_id_seq', 4);

insert into sales_reps (id, company_id, name) values
  (1, 1, 'Saji'), (2, 1, 'Kumar'), (3, 3, 'Nimal');
select setval('sales_reps_id_seq', 3);

-- GRN, company 1 (free units + discount on one line)
insert into tx_header (doc_no, company_id, date, type, posted_by)
values ('GRN-260901-001', 1, '2026-09-01', 'GRN', 'aaaaaaaa-0000-0000-0000-000000000001');
insert into tx_lines (doc_no, item_id, qty_cases, qty_units, free_units, disc_pct, disc_amt, unit_price) values
  ('GRN-260901-001', 1, 10, 0, 5, 2, 0, 145.45),
  ('GRN-260901-001', 2,  5, 0, 0, 0, 100, 82.50);

-- GRN, company 3, same day (old numbering counted per company; 002 here)
insert into tx_header (doc_no, company_id, date, type, posted_by)
values ('GRN-260901-002', 3, '2026-09-01', 'GRN', 'aaaaaaaa-0000-0000-0000-000000000002');
insert into tx_lines (doc_no, item_id, qty_cases, qty_units, unit_price) values
  ('GRN-260901-002', 3, 4, 0, 200.00);

-- ISSUE to Saji
insert into tx_header (doc_no, company_id, date, type, rep_id, posted_by)
values ('ISS-260902-001', 1, '2026-09-02', 'ISS', 1, 'aaaaaaaa-0000-0000-0000-000000000001');
insert into tx_lines (doc_no, item_id, qty_cases, qty_units, unit_price) values
  ('ISS-260902-001', 1, 2,  0, 145.45),
  ('ISS-260902-001', 2, 1, 10,  82.50);

-- RETURN from Saji
insert into tx_header (doc_no, company_id, date, type, rep_id, posted_by)
values ('RET-260903-001', 1, '2026-09-03', 'RET', 1, 'aaaaaaaa-0000-0000-0000-000000000001');
insert into tx_lines (doc_no, item_id, qty_cases, qty_units, unit_price) values
  ('RET-260903-001', 1, 0, 20, 145.45);

-- ISSUE to Kumar, later reversed the legacy way (no trigger support for
-- REV, so balances were corrected by hand).
insert into tx_header (doc_no, company_id, date, type, rep_id, posted_by)
values ('ISS-260904-001', 1, '2026-09-04', 'ISS', 2, 'aaaaaaaa-0000-0000-0000-000000000001');
insert into tx_lines (doc_no, item_id, qty_cases, qty_units, unit_price) values
  ('ISS-260904-001', 1, 1, 0, 145.45);

insert into tx_header (doc_no, company_id, date, type, rep_id, posted_by, reversal_of)
values ('REV-260904-001', 1, '2026-09-04', 'REV', 2, 'aaaaaaaa-0000-0000-0000-000000000001', 'ISS-260904-001');
insert into tx_lines (doc_no, item_id, qty_cases, qty_units, unit_price) values
  ('REV-260904-001', 1, 1, 0, 145.45);
update tx_header set status = 'reversed', reversed_by = 'REV-260904-001' where doc_no = 'ISS-260904-001';
update stock_ledger set qty_units = qty_units + 48 where item_id = 1;
update rep_ledger   set qty_units_held = qty_units_held - 48 where rep_id = 2 and item_id = 1;

-- ADJUSTMENT: 7 damaged units written off (negative quantity, manual stock fix)
insert into tx_header (doc_no, company_id, date, type, remarks, posted_by)
values ('AJUST-260905-001', 1, '2026-09-05', 'AJUST', 'Damaged', 'aaaaaaaa-0000-0000-0000-000000000001');
insert into tx_lines (doc_no, item_id, qty_cases, qty_units, unit_price) values
  ('AJUST-260905-001', 2, 0, -7, 82.50);
update stock_ledger set qty_units = qty_units - 7 where item_id = 2;

-- Snapshot of balances before migration, for comparison afterwards.
create table _before_stock as select company_id, item_id, qty_units from stock_ledger;
create table _before_rep   as select company_id, rep_id, item_id, qty_units_held from rep_ledger;
create table _before_docs  as select doc_no, type, status from tx_header;
