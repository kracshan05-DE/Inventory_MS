-- =====================================================================
-- InventoryIQ  |  02_cutover_corrections.sql
-- Run once, straight after 01_migration.sql. Safe to run again.
--
-- The old system let 25 balances drift away from the documents
-- (see 00b_diagnose_differences.sql, run on 2026-10-02).
--
-- Decision taken: NO BALANCE IS CHANGED. Every figure the owner sees
-- today stays exactly as it is. Each gap is written to opening_balances
-- with its cause, so the app starts with everything reconciled and any
-- difference that appears later is a new one.
--
-- One transaction: if the final check fails, nothing is applied.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- A. Reversed issues that were never taken off the rep        (16 rows)
--
--    ISS-260703-002  NIRO   reversed by REV-260719-001  "2 TIME ENTRY"
--    ISS-260711-002  NIRO   reversed by REV-260719-002  "TWO TIME ENTRY"
--    ISS-260728-001  THAYA  reversed by REV-260728-001  "WRONG DATE"
--
--    The old reversal put the stock back in the warehouse and left it on
--    the rep, so these rep balances are higher than the documents by
--    exactly the reversed quantity. Kept as they are.
-- ---------------------------------------------------------------------
select public.cutover_keep_reversed_issues() as reversed_issue_rows_recorded;

-- ---------------------------------------------------------------------
-- B. Returns entered while the rep balance was zero            (4 rows)
--    The old trigger added the stock to the warehouse and dropped the
--    rep side of the return.
-- ---------------------------------------------------------------------
select public.cutover_resolve('Unilever', 'SUNSILK 80ML 340/= BLACK', 'Roy', 'keep_ledger',
  'Return of 48 units with no issue to this rep in the system. Balance kept as it was.');

select public.cutover_resolve(null, 'L.B SAMPOO 80 ML 300/=', 'Saji', 'keep_ledger',
  'Return of 144 units with no issue to this rep in the system. Balance kept as it was.');

select public.cutover_resolve('NO 07', 'CHIT CHAT 15/=', 'KIR', 'keep_ledger',
  'A return of 11 cases was entered while the rep balance was zero, so the old system did not deduct it. Balance kept as it was.');

select public.cutover_resolve('Unilever', 'L.BOY 160/=', 'Saji', 'keep_ledger',
  'A return of 2 cases was entered while the rep balance was zero, so the old system did not deduct it. Balance kept as it was.');

-- ---------------------------------------------------------------------
-- C. Units per case edited after posting                       (3 rows)
--    SAPTHAMI BEEDI was posted at 100 units per case; the item now says 30.
-- ---------------------------------------------------------------------
select public.cutover_resolve('NO 07', 'SAPTHAMI BEEDI', null, 'keep_ledger',
  'Posted at 100 units per case, item now says 30. Balance kept as it was.');
select public.cutover_resolve('NO 07', 'SAPTHAMI BEEDI', 'NIRO', 'keep_ledger',
  'Posted at 100 units per case, item now says 30. Balance kept as it was.');
select public.cutover_resolve('NO 07', 'SAPTHAMI BEEDI', 'THAYA', 'keep_ledger',
  'Posted at 100 units per case, item now says 30. Balance kept as it was.');

-- ---------------------------------------------------------------------
-- D. Stock changed outside any document                        (2 rows)
-- ---------------------------------------------------------------------
select public.cutover_resolve('NO 07', 'AMRITHA 110/=', null, 'keep_ledger',
  'Stock is 235 units below the documents (ledger last touched 2026-09-09, no document). Balance kept as it was.');

select public.cutover_resolve('Unilever', 'SIGNAL 120G 240/=', null, 'keep_ledger',
  'Stock is 48 units above the documents (ledger last touched 2026-09-08, no document). Balance kept as it was.');

-- ---------------------------------------------------------------------
-- E. Final check. Every balance must now reconcile. If something new
--    appeared since the diagnosis, stop here and change nothing.
-- ---------------------------------------------------------------------
do $$
declare
  v_left text;
begin
  select string_agg(
           format('%s | %s | %s | balance %s, documents %s, diff %s',
                  d.kind, d.company, coalesce(d.rep || ' / ', '') || d.item,
                  d.ledger, d.expected, d.diff),
           E'\n' order by d.kind, d.company, d.rep, d.item)
    into v_left
  from public.cutover_differences() d;

  if v_left is not null then
    raise exception E'Cutover stopped, nothing was changed. These balances are still unexplained:\n%\nRun 00b_diagnose_differences.sql again and send the result.', v_left;
  end if;
end $$;

commit;

-- What was recorded.
select coalesce(rep_name, 'warehouse') as held_by, item_name, units as opening_difference, reason
from public.v_opening_balances
order by reason, item_name, held_by;

-- ---------------------------------------------------------------------
-- LATER, if a balance should be corrected after all (each is logged in
-- audit_log with the old and new value):
--
--   One balance, set to what the documents say:
--     select public.cutover_resolve('NO 07', 'CHIT CHAT 15/=', 'KIR',
--            'use_documents', 'reason here');
--
--   All 16 reversed-issue rows at once:
--     delete from public.opening_balances where reason like 'Reversed issue:%';
--     select public.cutover_fix_reversed_issues();
-- ---------------------------------------------------------------------
