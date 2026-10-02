-- =====================================================================
-- InventoryIQ  |  00b_diagnose_differences.sql
-- READ ONLY. Changes nothing. Run when 00_preflight_check.sql reports
-- differences. The result is one cell of text. Copy it.
--
-- For every balance that disagrees with the documents it prints the
-- numbers needed to tell WHY:
--   * every adjustment, reversal and reversed document, with its lines
--   * what the old stock trigger alone would have produced ("trigger")
--   * net cases and loose units, to detect a units-per-case edit
-- =====================================================================

with
lines as (
  select l.id as line_id, h.doc_no, h.company_id, h.type, h.status, h.rep_id,
         l.item_id, l.qty_cases, l.qty_units, l.free_units, l.unit_price,
         i.units_per_case as upc,
         l.qty_cases * i.units_per_case + l.qty_units + l.free_units as total_units,
         l.qty_units + l.free_units as loose_units
  from public.tx_header h
  join public.tx_lines l on l.doc_no = h.doc_no
  join public.items i    on i.id = l.item_id
),

-- ---------- warehouse ----------
wh as (
  select item_id,
    coalesce(sum(total_units) filter (where type = 'GRN'   and status = 'active'), 0)   as grn,
    coalesce(sum(total_units) filter (where type = 'ISS'   and status = 'active'), 0)   as iss,
    coalesce(sum(total_units) filter (where type = 'RET'   and status = 'active'), 0)   as ret,
    coalesce(sum(total_units) filter (where type = 'AJUST' and status = 'active'), 0)   as adj,
    coalesce(sum(total_units) filter (where type = 'GRN'   and status = 'reversed'), 0) as grn_rev,
    coalesce(sum(total_units) filter (where type = 'ISS'   and status = 'reversed'), 0) as iss_rev,
    coalesce(sum(total_units) filter (where type = 'RET'   and status = 'reversed'), 0) as ret_rev,
    -- what the old trigger did on its own: every GRN/ISS/RET line ever
    -- inserted, reversed or not; it ignored AJUST and REV
    coalesce(sum(case type when 'GRN' then total_units when 'ISS' then -total_units
                           when 'RET' then total_units else 0 end), 0)                  as trigger_units,
    coalesce(sum(case when status = 'active' then
                   case type when 'GRN' then qty_cases when 'ISS' then -qty_cases
                             when 'RET' then qty_cases when 'AJUST' then qty_cases else 0 end
                 else 0 end), 0)                                                         as net_cases,
    coalesce(sum(case when status = 'active' then
                   case type when 'GRN' then loose_units when 'ISS' then -loose_units
                             when 'RET' then loose_units when 'AJUST' then loose_units else 0 end
                 else 0 end), 0)                                                         as net_loose
  from lines
  group by item_id
),
wh_cmp as (
  select i.id as item_id, c.name as company, i.name as item, i.units_per_case as upc,
         coalesce(s.qty_units, 0) as ledger, s.last_updated,
         coalesce(w.grn,0) grn, coalesce(w.iss,0) iss, coalesce(w.ret,0) ret, coalesce(w.adj,0) adj,
         coalesce(w.grn_rev,0) grn_rev, coalesce(w.iss_rev,0) iss_rev, coalesce(w.ret_rev,0) ret_rev,
         coalesce(w.trigger_units,0) trigger_units,
         coalesce(w.net_cases,0) net_cases, coalesce(w.net_loose,0) net_loose,
         coalesce(w.grn,0) + coalesce(w.adj,0) - coalesce(w.iss,0) + coalesce(w.ret,0) as docs
  from public.items i
  join public.companies c on c.id = i.company_id
  left join public.stock_ledger s on s.item_id = i.id and s.company_id = i.company_id
  left join wh w on w.item_id = i.id
),

-- ---------- reps ----------
rep_steps as (
  -- every ISS/RET line ever inserted, in insertion order, as the trigger saw it
  select rep_id, item_id, line_id,
         sum(case type when 'ISS' then total_units else -total_units end)
           over (partition by rep_id, item_id order by line_id) as running
  from lines
  where type in ('ISS','RET') and rep_id is not null
),
rep_trigger as (
  -- the trigger floored returns at zero: final = sum - min(0, lowest running total)
  select rep_id, item_id,
         (array_agg(running order by line_id desc))[1] - least(0, min(running)) as trigger_units
  from rep_steps
  group by rep_id, item_id
),
rp as (
  select rep_id, item_id,
    coalesce(sum(total_units) filter (where type = 'ISS' and status = 'active'), 0)   as iss,
    coalesce(sum(total_units) filter (where type = 'RET' and status = 'active'), 0)   as ret,
    coalesce(sum(total_units) filter (where type = 'ISS' and status = 'reversed'), 0) as iss_rev,
    coalesce(sum(total_units) filter (where type = 'RET' and status = 'reversed'), 0) as ret_rev,
    coalesce(sum(case when status = 'active' then
                   case type when 'ISS' then qty_cases when 'RET' then -qty_cases else 0 end
                 else 0 end), 0) as net_cases,
    coalesce(sum(case when status = 'active' then
                   case type when 'ISS' then loose_units when 'RET' then -loose_units else 0 end
                 else 0 end), 0) as net_loose
  from lines
  where type in ('ISS','RET') and rep_id is not null
  group by rep_id, item_id
),
rep_cmp as (
  select coalesce(rl.rep_id, rp.rep_id) as rep_id, coalesce(rl.item_id, rp.item_id) as item_id,
         coalesce(rl.qty_units_held, 0) as ledger, rl.last_updated,
         coalesce(rp.iss,0) iss, coalesce(rp.ret,0) ret, coalesce(rp.iss_rev,0) iss_rev, coalesce(rp.ret_rev,0) ret_rev,
         coalesce(rp.net_cases,0) net_cases, coalesce(rp.net_loose,0) net_loose,
         coalesce(rp.iss,0) - coalesce(rp.ret,0) as docs
  from public.rep_ledger rl
  full join rp on rp.rep_id = rl.rep_id and rp.item_id = rl.item_id
),

report as (
  -- A. the unusual documents, in full
  select 100 as ord, h.created_at as ts, h.doc_no as k, 0 as n,
         'DOC ' || h.doc_no || ' | ' || h.type || '/' || h.status
           || ' | date ' || h.date::text
           || ' | ' || c.name
           || ' | rep ' || coalesce(r.name, '-')
           || coalesce(' | reversal_of ' || h.reversal_of, '')
           || coalesce(' | reversed_by ' || h.reversed_by, '')
           || ' | posted ' || to_char(h.created_at at time zone 'Asia/Colombo', 'YYYY-MM-DD HH24:MI')
           || ' | remarks: ' || coalesce(h.remarks, '-') as line
  from public.tx_header h
  join public.companies c on c.id = h.company_id
  left join public.sales_reps r on r.id = h.rep_id
  where h.type in ('AJUST','REV') or h.status = 'reversed'

  union all
  select 100, h.created_at, h.doc_no, l.line_id,
         '      line | ' || i.name
           || ' | cases ' || l.qty_cases::text || ' units ' || l.qty_units::text || ' free ' || l.free_units::text
           || ' | per case now ' || l.upc::text
           || ' | total now ' || l.total_units::text
  from lines l
  join public.tx_header h on h.doc_no = l.doc_no
  join public.items i on i.id = l.item_id
  where h.type in ('AJUST','REV') or h.status = 'reversed'

  -- B. warehouse differences
  union all
  select 200, null, company || item, 0,
         'WAREHOUSE ' || company || ' | ' || item
           || ' | per case now ' || upc::text
           || ' | ledger ' || ledger::text || ' docs ' || docs::text || ' diff ' || (ledger - docs)::text
           || ' | trigger ' || trigger_units::text
           || ' | active: GRN ' || grn::text || ' ISS ' || iss::text || ' RET ' || ret::text || ' AJUST ' || adj::text
           || ' | reversed: GRN ' || grn_rev::text || ' ISS ' || iss_rev::text || ' RET ' || ret_rev::text
           || ' | net cases ' || net_cases::text || ' net loose ' || net_loose::text
           || ' | ledger updated ' || coalesce(to_char(last_updated at time zone 'Asia/Colombo', 'YYYY-MM-DD HH24:MI'), '-')
  from wh_cmp
  where ledger <> docs

  -- C. rep differences
  union all
  select 300, null, coalesce(r.name, '?') || coalesce(i.name, '?'), 0,
         'REP ' || coalesce(r.name, '?') || ' | ' || coalesce(i.name, '?')
           || ' | per case now ' || coalesce(i.units_per_case::text, '?')
           || ' | ledger ' || d.ledger::text || ' docs ' || d.docs::text || ' diff ' || (d.ledger - d.docs)::text
           || ' | trigger ' || coalesce(t.trigger_units::text, '0')
           || ' | active: ISS ' || d.iss::text || ' RET ' || d.ret::text
           || ' | reversed: ISS ' || d.iss_rev::text || ' RET ' || d.ret_rev::text
           || ' | net cases ' || d.net_cases::text || ' net loose ' || d.net_loose::text
           || ' | ledger updated ' || coalesce(to_char(d.last_updated at time zone 'Asia/Colombo', 'YYYY-MM-DD HH24:MI'), '-')
  from rep_cmp d
  left join rep_trigger t on t.rep_id = d.rep_id and t.item_id = d.item_id
  left join public.sales_reps r on r.id = d.rep_id
  left join public.items i      on i.id = d.item_id
  where d.ledger <> d.docs
)
select string_agg(line, E'\n' order by ord, ts, k, n) as diagnosis
from report;
