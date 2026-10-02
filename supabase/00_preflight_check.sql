-- =====================================================================
-- InventoryIQ  |  00_preflight_check.sql
-- READ ONLY. Changes nothing. Run before 01_migration.sql.
--
-- It answers one question: do the existing documents explain the
-- existing balances? The result is one cell of text. Copy it.
--
-- Rule used (same rule the new app uses):
--   warehouse = GRN + AJUST - ISS + RET     (active documents only)
--   with reps = ISS - RET                   (active documents only)
-- Reversed documents and REV documents are left out.
-- =====================================================================

with
lines as (
  select h.doc_no, h.company_id, h.type, h.status, h.rep_id,
         l.item_id, l.unit_price,
         l.qty_cases * i.units_per_case + l.qty_units + l.free_units as total_units,
         l.qty_cases, l.qty_units, l.free_units,
         i.company_id as item_company_id
  from public.tx_header h
  join public.tx_lines l on l.doc_no = h.doc_no
  join public.items i    on i.id = l.item_id
),
calc_stock as (
  select item_id,
         sum(case type when 'GRN'   then total_units
                       when 'AJUST' then total_units
                       when 'ISS'   then -total_units
                       when 'RET'   then total_units
                       else 0 end) as units
  from lines
  where status = 'active' and type <> 'REV'
  group by item_id
),
stock_cmp as (
  select i.id as item_id, i.name, c.name as company,
         coalesce(s.qty_units, 0) as ledger_units,
         coalesce(cs.units, 0)    as document_units
  from public.items i
  join public.companies c on c.id = i.company_id
  left join public.stock_ledger s on s.item_id = i.id and s.company_id = i.company_id
  left join calc_stock cs on cs.item_id = i.id
),
calc_rep as (
  select rep_id, item_id,
         sum(case type when 'ISS' then total_units
                       when 'RET' then -total_units
                       else 0 end) as units
  from lines
  where status = 'active' and type in ('ISS','RET') and rep_id is not null
  group by rep_id, item_id
),
rep_cmp as (
  select coalesce(rl.rep_id, cr.rep_id)   as rep_id,
         coalesce(rl.item_id, cr.item_id) as item_id,
         coalesce(rl.qty_units_held, 0)   as ledger_units,
         coalesce(cr.units, 0)            as document_units
  from public.rep_ledger rl
  full join calc_rep cr on cr.rep_id = rl.rep_id and cr.item_id = rl.item_id
),
report as (
  select 10 as ord, 'documents' as section,
         type || ' / ' || status || ': ' || count(*)::text || ' docs' as line
  from public.tx_header group by type, status

  union all
  select 20, 'lines per type',
         h.type || ': ' || count(l.id)::text || ' lines, '
           || count(*) filter (where l.qty_cases < 0 or l.qty_units < 0)::text || ' with negative qty, '
           || count(*) filter (where l.id is not null and l.unit_price = 0)::text || ' with price 0'
  from public.tx_header h
  left join public.tx_lines l on l.doc_no = h.doc_no
  group by h.type

  union all
  select 30, 'reversal links',
         'reversed docs: ' || count(*) filter (where status = 'reversed')::text
         || ', of which reversed_by is set: '
         || count(*) filter (where status = 'reversed' and reversed_by is not null)::text
         || ' | REV docs: ' || count(*) filter (where type = 'REV')::text
         || ', of which reversal_of is set: '
         || count(*) filter (where type = 'REV' and reversal_of is not null)::text
  from public.tx_header

  union all
  select 40, 'warehouse check',
         'items where stock_ledger <> documents: '
           || count(*) filter (where ledger_units <> document_units)::text
           || ' of ' || count(*)::text
  from stock_cmp

  union all
  select 41, 'warehouse differences (first 30)',
         company || ' | ' || name || ' | ledger ' || ledger_units::text
           || ' | documents ' || document_units::text
           || ' | diff ' || (ledger_units - document_units)::text
  from (select * from stock_cmp where ledger_units <> document_units
        order by abs(ledger_units - document_units) desc limit 30) d

  union all
  select 50, 'rep check',
         'rep/item balances where rep_ledger <> documents: '
           || count(*) filter (where ledger_units <> document_units)::text
           || ' of ' || count(*)::text
  from rep_cmp

  union all
  select 51, 'rep differences (first 30)',
         coalesce(r.name, '?') || ' | ' || coalesce(i.name, '?')
           || ' | ledger ' || d.ledger_units::text
           || ' | documents ' || d.document_units::text
           || ' | diff ' || (d.ledger_units - d.document_units)::text
  from (select * from rep_cmp where ledger_units <> document_units
        order by abs(ledger_units - document_units) desc limit 30) d
  left join public.sales_reps r on r.id = d.rep_id
  left join public.items i      on i.id = d.item_id

  union all
  select 60, 'negative balances',
         'stock_ledger rows below zero: '
           || (select count(*) from public.stock_ledger where qty_units < 0)::text
           || ' | rep_ledger rows below zero: '
           || (select count(*) from public.rep_ledger where qty_units_held < 0)::text

  union all
  select 70, 'cross-company rows',
         'lines whose item belongs to another company: '
           || (select count(*) from lines where item_company_id <> company_id)::text
           || ' | documents whose rep belongs to another company: '
           || (select count(*) from public.tx_header h
               join public.sales_reps r on r.id = h.rep_id
               where r.company_id <> h.company_id)::text

  union all
  select 80, 'items',
         'units_per_case below 1: '
           || (select count(*) from public.items where units_per_case < 1)::text
           || ' | negative price: '
           || (select count(*) from public.items where unit_price < 0)::text

  union all
  select 90, 'doc number formats',
         regexp_replace(doc_no, '[0-9]', '9', 'g') || ' : ' || count(*)::text
  from public.tx_header
  group by regexp_replace(doc_no, '[0-9]', '9', 'g')

  union all
  select 100, 'users',
         role || ' / ' || case when company_id is null then 'no company' else 'company ' || company_id::text end
           || ': ' || count(*)::text
  from public.user_profiles group by role, company_id
)
select string_agg('[' || section || '] ' || line, E'\n' order by ord, line) as preflight_report
from report;
