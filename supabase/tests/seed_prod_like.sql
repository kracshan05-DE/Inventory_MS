-- Rebuilds, on the pre-migration schema, the 25 differences found in
-- production on 2026-10-02: same companies, reps, items, pack sizes and
-- the same three faults of the old system. Used to rehearse
-- 01_migration.sql + 02_cutover_corrections.sql end to end.
\set ON_ERROR_STOP on

insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'uncle@example.com', '{"full_name":"Uncle"}');
insert into companies (id, name) values (1, 'Unilever'), (2, 'NO 07');
select setval('companies_id_seq', 2);
update user_profiles set role = 'admin', company_id = 1;

insert into items (company_id, name, units_per_case, unit_price) values
  (1, 'SUNLIGHT LIQUIT 700/=', 15, 600), (1, 'VIVA 400G 720/=', 24, 650),
  (1, 'SIGNAL 40G 125/=', 72, 110),      (1, 'SIGNAL 70G 200/=', 72, 180),
  (1, 'SIGNAL 200G 340/=', 48, 300),     (1, 'L.BOY 160/=', 147, 140),
  (1, 'L SAMPOO 175ML 520/=', 22, 470),  (1, 'L SAMPOO PROMATION 300/=', 32, 270),
  (1, 'SUNSLIK 180ML 480/= YELLOW', 24, 430), (1, 'SUNSILK 80ML 340/= BLACK', 48, 300),
  (1, 'SUNSLIK 180ML 625/= BLACK', 24, 560),  (1, 'SIGNAL 120G 240/=', 48, 215),
  (1, 'L.B SAMPOO 80 ML 300/=', 48, 270),     (1, 'S POWDER 340/=', 18, 300),
  (2, 'CHIT CHAT 15/=', 576, 12),  (2, 'EVA 50/=', 60, 44),   (2, 'EVA 270/=', 24, 240),
  (2, 'SAMAPOSA 195/=', 25, 170),  (2, 'BUBLEEGUM 5/=', 30, 4), (2, 'SAPTHAMI BEEDI', 100, 90),
  (2, 'AMRITHA 110/=', 144, 95),   (2, 'CHO FRESH C M P 90/=', 144, 80), (2, 'VIM SET 4PCS 180/=', 36, 160);

insert into sales_reps (company_id, name) values
  (1, 'NIRO'), (1, 'Saji'), (1, 'Roy'), (2, 'NIRO'), (2, 'THAYA'), (2, 'KIR');

-- Posts a document the way the old pages did: header, then lines, with the
-- old trigger moving stock. lines = [[item name, cases, loose units], ...]
create function _old_post(p_doc text, p_company int, p_date date, p_type text, p_rep text, p_lines jsonb)
returns void language plpgsql as $$
declare e jsonb;
begin
  insert into tx_header (doc_no, company_id, date, type, rep_id, posted_by)
  values (p_doc, p_company, p_date, p_type,
          (select id from sales_reps where company_id = p_company and name = p_rep),
          'aaaaaaaa-0000-0000-0000-000000000001');
  for e in select * from jsonb_array_elements(p_lines) loop
    insert into tx_lines (doc_no, item_id, qty_cases, qty_units, unit_price)
    select p_doc, i.id, (e->>1)::int, coalesce((e->>2)::int, 0), i.unit_price
    from items i where i.company_id = p_company and i.name = e->>0;
  end loop;
end $$;

-- The legacy reversal page: restores the warehouse, forgets the rep.
create function _old_reverse(p_doc text, p_rev text, p_reason text)
returns void language plpgsql as $$
declare h tx_header%rowtype; l record;
begin
  select * into h from tx_header where doc_no = p_doc;
  insert into tx_header (doc_no, company_id, date, type, remarks, posted_by, reversal_of)
  values (p_rev, h.company_id, h.date, 'REV', 'REVERSAL of ' || p_doc || ': ' || p_reason, h.posted_by, p_doc);
  for l in select tl.*, i.units_per_case from tx_lines tl join items i on i.id = tl.item_id where tl.doc_no = p_doc loop
    insert into tx_lines (doc_no, item_id, qty_cases, qty_units, unit_price)
    values (p_rev, l.item_id, l.qty_cases, l.qty_units, l.unit_price);
    update stock_ledger
       set qty_units = qty_units + (case h.type when 'ISS' then 1 else -1 end) * (l.qty_cases * l.units_per_case + l.qty_units)
     where item_id = l.item_id;
  end loop;
  update tx_header set status = 'reversed', reversed_by = p_rev where doc_no = p_doc;
end $$;

-- Goods received
select _old_post('GRN-260601-001', 1, '2026-06-01', 'GRN', null, '[
  ["SUNLIGHT LIQUIT 700/=",10],["VIVA 400G 720/=",10],["SIGNAL 40G 125/=",30],["SIGNAL 70G 200/=",10],
  ["SIGNAL 200G 340/=",10],["L.BOY 160/=",20],["L SAMPOO 175ML 520/=",10],["L SAMPOO PROMATION 300/=",10],
  ["SUNSLIK 180ML 480/= YELLOW",10],["SUNSILK 80ML 340/= BLACK",10],["SUNSLIK 180ML 625/= BLACK",10],
  ["SIGNAL 120G 240/=",37],["L.B SAMPOO 80 ML 300/=",5],["S POWDER 340/=",4]]');
select _old_post('GRN-260601-002', 2, '2026-06-01', 'GRN', null, '[
  ["CHIT CHAT 15/=",60],["EVA 50/=",60],["EVA 270/=",100],["SAMAPOSA 195/=",120],["BUBLEEGUM 5/=",10],
  ["SAPTHAMI BEEDI",3],["AMRITHA 110/=",7,343]]');

-- Imported adjustment: carries a rep, counted as stock in, ledger set by the import
select _old_post('DOC-260512-001', 1, '2026-05-12', 'AJUST', 'Saji', '[["L SAMPOO PROMATION 300/=",2],["S POWDER 340/=",6]]');
update tx_header set remarks = 'Adjustment - Imported' where doc_no = 'DOC-260512-001';
update stock_ledger s set qty_units = qty_units + 64  from items i where i.id = s.item_id and i.name = 'L SAMPOO PROMATION 300/=';
update stock_ledger s set qty_units = qty_units + 108 from items i where i.id = s.item_id and i.name = 'S POWDER 340/=';

-- FAULT 1: duplicate issues, reversed the old way (rep balance left behind)
select _old_post('ISS-260703-001', 1, '2026-07-03', 'ISS', 'NIRO', '[["SUNLIGHT LIQUIT 700/=",1]]');
select _old_post('ISS-260703-002', 1, '2026-07-03', 'ISS', 'NIRO', '[["SUNLIGHT LIQUIT 700/=",1]]');
select _old_post('ISS-260711-001', 1, '2026-07-11', 'ISS', 'NIRO', '[
  ["VIVA 400G 720/=",2],["SIGNAL 40G 125/=",17],["SIGNAL 70G 200/=",2],["SIGNAL 200G 340/=",3],["L.BOY 160/=",5],
  ["L SAMPOO 175ML 520/=",2],["L SAMPOO PROMATION 300/=",4],["SUNSLIK 180ML 480/= YELLOW",2],
  ["SUNSILK 80ML 340/= BLACK",2],["SUNSLIK 180ML 625/= BLACK",2]]');
select _old_post('ISS-260711-002', 1, '2026-07-11', 'ISS', 'NIRO', '[
  ["VIVA 400G 720/=",2],["SIGNAL 40G 125/=",5],["SIGNAL 70G 200/=",2],["SIGNAL 200G 340/=",2],["L.BOY 160/=",2],
  ["L SAMPOO 175ML 520/=",2],["L SAMPOO PROMATION 300/=",2],["SUNSLIK 180ML 480/= YELLOW",2],
  ["SUNSILK 80ML 340/= BLACK",4],["SUNSLIK 180ML 625/= BLACK",2]]');
select _old_post('ISS-260712-001', 1, '2026-07-12', 'ISS', 'NIRO', '[["VIVA 400G 720/=",2]]');
select _old_reverse('ISS-260703-002', 'REV-260719-001', '2 TIME ENTRY');
select _old_reverse('ISS-260711-002', 'REV-260719-002', 'TWO TIME ENTRY');

select _old_post('GRN-260723-002', 2, '2026-07-23', 'GRN', null, '[["CHO FRESH C M P 90/=",4],["VIM SET 4PCS 180/=",25]]');
select _old_reverse('GRN-260723-002', 'REV-260723-001', 'DATE ISH');

select _old_post('ISS-260728-001', 2, '2026-07-28', 'ISS', 'THAYA', '[
  ["CHIT CHAT 15/=",1],["EVA 50/=",2],["EVA 270/=",2],["SAMAPOSA 195/=",2],["BUBLEEGUM 5/=",1]]');
select _old_reverse('ISS-260728-001', 'REV-260728-001', 'WRONG DATE');
select _old_post('ISS-260729-001', 2, '2026-07-29', 'ISS', 'THAYA', '[
  ["CHIT CHAT 15/=",17],["EVA 50/=",50],["EVA 270/=",89],["SAMAPOSA 195/=",100],["BUBLEEGUM 5/=",5]]');

-- FAULT 2: returns entered while the rep balance was zero (trigger drops the rep side)
select _old_post('RET-260715-001', 2, '2026-07-15', 'RET', 'KIR',  '[["CHIT CHAT 15/=",11]]');
select _old_post('ISS-260716-001', 2, '2026-07-16', 'ISS', 'KIR',  '[["CHIT CHAT 15/=",22],["AMRITHA 110/=",3,108]]');
select _old_post('RET-260820-001', 1, '2026-08-20', 'RET', 'Saji', '[["L.BOY 160/=",2]]');
select _old_post('ISS-260821-001', 1, '2026-08-21', 'ISS', 'Saji', '[["L.BOY 160/=",5],["SIGNAL 120G 240/=",32]]');
select _old_post('RET-260822-001', 1, '2026-08-22', 'RET', 'Roy',  '[["SUNSILK 80ML 340/= BLACK",1]]');
select _old_post('RET-260823-001', 1, '2026-08-23', 'RET', 'Saji', '[["L.B SAMPOO 80 ML 300/=",3]]');

-- FAULT 3a: units per case edited after posting (100 -> 30)
select _old_post('ISS-260616-001', 2, '2026-06-16', 'ISS', 'THAYA', '[["SAPTHAMI BEEDI",1]]');
select _old_post('ISS-260719-001', 2, '2026-07-19', 'ISS', 'NIRO',  '[["SAPTHAMI BEEDI",1]]');
update items set units_per_case = 30 where name = 'SAPTHAMI BEEDI';

-- FAULT 3b: stock edited by hand, outside any document
update stock_ledger s set qty_units = 576 from items i where i.id = s.item_id and i.name = 'AMRITHA 110/=';
update stock_ledger s set qty_units = qty_units + 48 from items i where i.id = s.item_id and i.name = 'SIGNAL 120G 240/=';

drop function _old_post(text, int, date, text, text, jsonb);
drop function _old_reverse(text, text, text);

create table _before_stock as select company_id, item_id, qty_units from stock_ledger;
create table _before_rep   as select company_id, rep_id, item_id, qty_units_held from rep_ledger;
