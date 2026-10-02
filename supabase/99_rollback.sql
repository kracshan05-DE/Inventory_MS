-- =====================================================================
-- InventoryIQ  |  99_rollback.sql
-- Only if you need the OLD HTML pages to work again.
--
-- Restores the original trigger, policies and privileges so the old
-- pages can post. It keeps everything the new app recorded.
--
-- Warning: after this, the old "allow everything" access rules are back.
-- Documents posted by the old pages after a rollback will not have
-- locked units; run 01_migration.sql again to return to the new app.
-- =====================================================================

begin;

-- Old pages do not send the two new columns.
alter table public.tx_lines alter column units_per_case drop not null;
alter table public.tx_lines alter column total_units    drop not null;

-- Original stock trigger.
revoke all on function public.update_stock_on_transaction() from public;
drop trigger if exists trg_update_stock on public.tx_lines;
create trigger trg_update_stock
  after insert on public.tx_lines
  for each row execute function public.update_stock_on_transaction();

-- Original audit trigger.
drop trigger if exists trg_audit_tx_header on public.tx_header;
drop trigger if exists trg_audit_tx on public.tx_header;
create trigger trg_audit_tx
  after insert on public.tx_header
  for each row execute function public.log_transaction_audit();

-- New guard triggers off.
drop trigger if exists trg_audit_items                on public.items;
drop trigger if exists trg_audit_sales_reps           on public.sales_reps;
drop trigger if exists trg_audit_companies            on public.companies;
drop trigger if exists trg_audit_user_profiles        on public.user_profiles;
drop trigger if exists trg_audit_user_company_access  on public.user_company_access;
drop trigger if exists trg_items_company_fixed        on public.items;
drop trigger if exists trg_reps_company_fixed         on public.sales_reps;
drop trigger if exists trg_items_refresh_stock_value  on public.items;
drop trigger if exists trg_guard_last_admin           on public.user_profiles;

-- Original policies.
do $$
declare r record;
begin
  for r in
    select tablename, policyname from pg_policies
    where schemaname = 'public'
      and tablename in ('app_settings','audit_log','companies','daily_snapshots',
                        'items','rep_ledger','sales_reps','stock_ledger',
                        'tx_header','tx_lines','user_profiles')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

create policy settings_select on public.app_settings for select to authenticated using (true);
create policy settings_insert on public.app_settings for insert to authenticated with check (true);
create policy settings_update on public.app_settings for update to authenticated using (true) with check (true);

create policy audit_log_select on public.audit_log for select to authenticated using (true);
create policy audit_log_insert on public.audit_log for insert to authenticated with check (true);

create policy companies_select on public.companies for select to public using (true);
create policy companies_insert on public.companies for insert to authenticated with check (true);
create policy companies_update on public.companies for update to authenticated using (true) with check (true);

create policy snapshots_select on public.daily_snapshots for select to authenticated using (true);
create policy snapshots_insert on public.daily_snapshots for insert to authenticated with check (true);
create policy snapshots_update on public.daily_snapshots for update to authenticated using (true) with check (true);
create policy snapshots_delete on public.daily_snapshots for delete to authenticated using (true);

create policy items_select on public.items for select to authenticated using (true);
create policy items_insert on public.items for insert to authenticated with check (true);
create policy items_update on public.items for update to authenticated using (true) with check (true);
create policy items_delete on public.items for delete to authenticated using (true);

create policy rep_ledger_select on public.rep_ledger for select to authenticated using (true);
create policy rep_ledger_insert on public.rep_ledger for insert to authenticated with check (true);
create policy rep_ledger_update on public.rep_ledger for update to authenticated using (true) with check (true);
create policy rep_ledger_delete on public.rep_ledger for delete to authenticated using (true);

create policy reps_select on public.sales_reps for select to authenticated using (true);
create policy reps_insert on public.sales_reps for insert to authenticated with check (true);
create policy reps_update on public.sales_reps for update to authenticated using (true) with check (true);
create policy reps_delete on public.sales_reps for delete to authenticated using (true);

create policy stock_select on public.stock_ledger for select to authenticated using (true);
create policy stock_insert on public.stock_ledger for insert to authenticated with check (true);
create policy stock_update on public.stock_ledger for update to authenticated using (true) with check (true);
create policy stock_delete on public.stock_ledger for delete to authenticated using (true);

create policy tx_header_select on public.tx_header for select to authenticated using (true);
create policy tx_header_insert on public.tx_header for insert to authenticated with check (true);
create policy tx_header_update on public.tx_header for update to authenticated using (true) with check (true);
create policy tx_header_delete on public.tx_header for delete to authenticated using (true);

create policy tx_lines_select on public.tx_lines for select to authenticated using (true);
create policy tx_lines_insert on public.tx_lines for insert to authenticated with check (true);
create policy tx_lines_update on public.tx_lines for update to authenticated using (true) with check (true);
create policy tx_lines_delete on public.tx_lines for delete to authenticated using (true);

create policy user_profiles_select on public.user_profiles for select to authenticated using (true);
create policy user_profiles_insert on public.user_profiles for insert to public with check (true);
create policy user_profiles_update on public.user_profiles for update to authenticated using (true) with check (true);

-- Original privileges.
grant all on all tables in schema public to anon, authenticated;

-- Old dashboard reads these as the signed-in user.
grant select on public.v_active_transactions, public.v_financial_summary,
                public.v_rep_performance, public.v_stock_summary to authenticated;

commit;

notify pgrst, 'reload schema';
