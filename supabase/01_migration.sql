-- =====================================================================
-- InventoryIQ  |  01_migration.sql
-- Run once in the Supabase SQL Editor (safe to re-run).
--
-- What it does
--   1. Access control: replaces the "allow everything" RLS policies.
--   2. Locks history: stores units-per-case and total units on each line.
--   3. Atomic posting: post_transaction() and reverse_transaction().
--   4. Document numbers: collision-free counter per type and day.
--   5. Audit: every change to master data and documents is logged.
--   6. Reporting views: totals computed in SQL, RLS applied.
--
-- What it does NOT do
--   It does not change any existing quantity, price, balance or document.
--   stock_ledger and rep_ledger keep the exact values they hold today.
--   Balances that disagree with the documents are dealt with separately,
--   one explicit decision each, in 02_cutover_corrections.sql.
--
-- The whole script runs in one transaction. If any statement fails,
-- nothing is applied.
-- =====================================================================

begin;

do $$
begin
  if to_regclass('public.tx_header') is null
     or to_regclass('public.tx_lines') is null
     or to_regclass('public.stock_ledger') is null
     or to_regclass('public.rep_ledger') is null
     or to_regclass('public.user_profiles') is null then
    raise exception 'InventoryIQ tables not found. Is this the right project?';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 1. ACCESS MODEL
--    admin : every company (principal)
--    user  : only companies listed in user_company_access
-- ---------------------------------------------------------------------

create table if not exists public.user_company_access (
  user_id    uuid not null references public.user_profiles(id) on delete cascade,
  company_id int  not null references public.companies(id),
  granted_at timestamptz not null default now(),
  primary key (user_id, company_id)
);

-- Carry over the single company each profile is tied to today.
insert into public.user_company_access (user_id, company_id)
select id, company_id
from public.user_profiles
where company_id is not null
on conflict do nothing;

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select role = 'admin' from user_profiles where id = auth.uid()),
    false)
$$;

-- Set-returning so RLS policies evaluate it once per query, not per row.
create or replace function public.accessible_company_ids()
returns setof int
language sql stable security definer set search_path = public
as $$
  select c.id
  from companies c
  where auth.uid() is not null
    and (
      public.is_admin()
      or exists (select 1 from user_company_access a
                 where a.user_id = auth.uid() and a.company_id = c.id)
    )
$$;

create or replace function public.can_access_company(p_company_id int)
returns boolean
language sql stable security definer set search_path = public
as $$
  select p_company_id in (select public.accessible_company_ids())
$$;

-- Existing helper: pin its search_path (security definer hardening).
alter function public.current_company_id() set search_path = public;


-- ---------------------------------------------------------------------
-- 2. LOCK HISTORY ON EACH LINE
--    Until now total units were recomputed from the item's CURRENT
--    units_per_case, so editing an item rewrote past documents.
-- ---------------------------------------------------------------------

alter table public.tx_lines add column if not exists units_per_case int;
alter table public.tx_lines add column if not exists total_units    int;

-- Backfill with today's units_per_case. This is the same number every
-- existing page and trigger has been using, so no report changes.
update public.tx_lines l
set units_per_case = i.units_per_case,
    total_units    = l.qty_cases * i.units_per_case + l.qty_units + l.free_units
from public.items i
where i.id = l.item_id
  and (l.units_per_case is null or l.total_units is null);

alter table public.tx_lines alter column units_per_case set not null;
alter table public.tx_lines alter column total_units    set not null;

-- New document type: SALE = rep settlement (unreturned stock confirmed sold).
alter table public.tx_header drop constraint if exists tx_header_type_check;
alter table public.tx_header add constraint tx_header_type_check
  check (type in ('GRN','ISS','RET','SALE','AJUST','REV'));

-- Validation for new and edited rows. NOT VALID = existing rows are not
-- re-checked, so the migration cannot fail on old data.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'items_units_per_case_check') then
    alter table public.items add constraint items_units_per_case_check
      check (units_per_case >= 1) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'items_unit_price_check') then
    alter table public.items add constraint items_unit_price_check
      check (unit_price >= 0) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'tx_lines_discount_check') then
    alter table public.tx_lines add constraint tx_lines_discount_check
      check (disc_pct >= 0 and disc_pct <= 100 and disc_amt >= 0) not valid;
  end if;
end $$;

-- Opening differences. A row says: "at cutover this balance was N units
-- away from what the documents add up to, and we chose to keep the
-- balance". rep_id null = warehouse. Reconciliation adds these to the
-- expected side, so the gap is recorded once instead of showing forever.
create table if not exists public.opening_balances (
  id         serial primary key,
  company_id int  not null references public.companies(id),
  item_id    int  not null references public.items(id),
  rep_id     int  references public.sales_reps(id),
  units      int  not null,
  reason     text not null,
  created_at timestamptz not null default now()
);
create index if not exists opening_balances_item_idx on public.opening_balances (item_id);

create index if not exists tx_lines_doc_no_idx        on public.tx_lines  (doc_no);
create index if not exists tx_lines_item_id_idx       on public.tx_lines  (item_id);
create index if not exists tx_header_company_date_idx on public.tx_header (company_id, date desc, created_at desc);
create index if not exists tx_header_rep_idx          on public.tx_header (rep_id) where rep_id is not null;
create index if not exists audit_log_company_time_idx on public.audit_log (company_id, created_at desc);
create index if not exists audit_log_time_idx         on public.audit_log (created_at desc);


-- ---------------------------------------------------------------------
-- 3. DOCUMENT NUMBERS
--    Old method: count existing rows in the browser. Two users posting
--    together got the same number. tx_header.doc_no is unique across
--    ALL companies, so the counter is global per type and day.
--    Format is unchanged: GRN-261002-001
-- ---------------------------------------------------------------------

create table if not exists public.doc_counters (
  prefix   text not null,
  doc_date date not null,
  last_seq int  not null,
  primary key (prefix, doc_date)
);

create or replace function public.next_doc_no(p_prefix text, p_date date)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_base text := p_prefix || '-' || to_char(p_date, 'YYMMDD') || '-';
  v_seq  int;
  v_doc  text;
begin
  -- First use for this type and day: start after the highest number
  -- already used by existing documents.
  insert into doc_counters (prefix, doc_date, last_seq)
  select p_prefix, p_date,
         coalesce(max(substring(doc_no from length(v_base) + 1)::int), 0)
  from tx_header
  where doc_no ~ ('^' || v_base || '[0-9]{1,9}$')
  on conflict do nothing;

  loop
    -- Row lock: concurrent posts queue here and each gets its own number.
    update doc_counters
       set last_seq = last_seq + 1
     where prefix = p_prefix and doc_date = p_date
    returning last_seq into v_seq;

    v_doc := v_base || lpad(v_seq::text, 3, '0');
    exit when not exists (select 1 from tx_header where doc_no = v_doc);
  end loop;

  return v_doc;
end $$;


-- ---------------------------------------------------------------------
-- 4. STOCK MOVEMENT (internal)
--    The only code path that writes stock_ledger and rep_ledger.
--    A decrease that would take a balance below zero is rejected.
-- ---------------------------------------------------------------------

create or replace function public.apply_movement(
  p_company_id  int,
  p_item_id     int,
  p_rep_id      int,
  p_stock_delta int,
  p_rep_delta   int
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_name  text;
  v_price numeric;
  v_stock int;
  v_held  int;
  v_rep   text;
begin
  select name, unit_price into v_name, v_price from items where id = p_item_id;

  if p_stock_delta <> 0 then
    select qty_units into v_stock
    from stock_ledger
    where company_id = p_company_id and item_id = p_item_id
    for update;

    if not found then
      insert into stock_ledger (company_id, item_id, qty_units, stock_value)
      values (p_company_id, p_item_id, 0, 0);
      v_stock := 0;
    end if;

    if p_stock_delta < 0 and v_stock + p_stock_delta < 0 then
      raise exception 'Not enough stock for "%": % units in the warehouse, % needed.',
        v_name, v_stock, -p_stock_delta
        using errcode = 'P0001';
    end if;

    update stock_ledger
       set qty_units    = v_stock + p_stock_delta,
           stock_value  = (v_stock + p_stock_delta) * v_price,
           last_updated = now()
     where company_id = p_company_id and item_id = p_item_id;
  end if;

  if p_rep_delta <> 0 then
    select qty_units_held into v_held
    from rep_ledger
    where company_id = p_company_id and rep_id = p_rep_id and item_id = p_item_id
    for update;

    v_held := coalesce(v_held, 0);

    if p_rep_delta < 0 and v_held + p_rep_delta < 0 then
      select name into v_rep from sales_reps where id = p_rep_id;
      raise exception '% holds only % units of "%", % needed.',
        coalesce(v_rep, 'This rep'), v_held, v_name, -p_rep_delta
        using errcode = 'P0001';
    end if;

    insert into rep_ledger (company_id, rep_id, item_id, qty_units_held)
    values (p_company_id, p_rep_id, p_item_id, v_held + p_rep_delta)
    on conflict (company_id, rep_id, item_id)
    do update set qty_units_held = excluded.qty_units_held,
                  last_updated   = now();
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 5. POST A TRANSACTION
--    One call = one database transaction. Header, lines, stock and rep
--    balances either all succeed or all roll back.
--
--    Effect of each type (T = total units of the line):
--      GRN    warehouse +T
--      ISS    warehouse -T , rep +T
--      RET    warehouse +T , rep -T
--      SALE                  rep -T      (settlement: sold, not returned)
--      AJUST  warehouse +T               (T may be negative; admin only)
--
--    p_lines: [{"item_id":1,"qty_cases":2,"qty_units":0,
--               "free_units":0,"disc_pct":0,"disc_amt":0}, ...]
-- ---------------------------------------------------------------------

create or replace function public.post_transaction(
  p_company_id int,
  p_type       text,
  p_date       date,
  p_rep_id     int,
  p_remarks    text,
  p_lines      jsonb
) returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_today   date := (now() at time zone 'Asia/Colombo')::date;
  v_remarks text := nullif(btrim(coalesce(p_remarks, '')), '');
  v_rep_id  int  := p_rep_id;
  v_prefix  text;
  v_doc     text;
  v_ids     int[];
  v_n       int;
  v_line    record;
  v_item    record;
  v_cases   int;
  v_units   int;
  v_free    int;
  v_discp   numeric;
  v_disca   numeric;
  v_total   int;
begin
  -- Who is calling, and may they?
  if v_uid is null then
    raise exception 'You are not signed in.' using errcode = '28000';
  end if;
  if not can_access_company(p_company_id) then
    raise exception 'You do not have access to this company.' using errcode = '42501';
  end if;
  if not exists (select 1 from companies where id = p_company_id and active) then
    raise exception 'This company is inactive.';
  end if;

  if p_type is null or p_type not in ('GRN','ISS','RET','SALE','AJUST') then
    raise exception 'Unknown transaction type "%".', p_type;
  end if;
  if p_type = 'AJUST' then
    if not is_admin() then
      raise exception 'Only an admin can post a stock adjustment.' using errcode = '42501';
    end if;
    if v_remarks is null then
      raise exception 'A stock adjustment needs a reason in Remarks.';
    end if;
  end if;

  if p_date is null then
    raise exception 'Date is required.';
  end if;
  if p_date > v_today then
    raise exception 'Date cannot be in the future.';
  end if;

  -- Sales rep
  if p_type in ('ISS','RET','SALE') then
    if v_rep_id is null then
      raise exception 'Select a sales rep.';
    end if;
    if not exists (select 1 from sales_reps
                   where id = v_rep_id and company_id = p_company_id) then
      raise exception 'This sales rep does not belong to this company.';
    end if;
    if p_type = 'ISS' and not exists (select 1 from sales_reps
                                      where id = v_rep_id and active) then
      raise exception 'This sales rep is inactive.';
    end if;
  else
    v_rep_id := null;
  end if;

  -- Lines
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Add at least one item line.';
  end if;
  if jsonb_array_length(p_lines) > 500 then
    raise exception 'Too many lines in one document (max 500).';
  end if;

  select array_agg(x.item_id order by x.item_id), count(*)
    into v_ids, v_n
  from jsonb_to_recordset(p_lines) as x(item_id int);

  if exists (select 1 from unnest(v_ids) u where u is null) then
    raise exception 'A line has no item selected.';
  end if;
  if (select count(distinct u) from unnest(v_ids) u) <> v_n then
    raise exception 'The same item appears twice. Merge it into one line.';
  end if;
  if (select count(*) from items
      where id = any(v_ids) and company_id = p_company_id) <> v_n then
    raise exception 'One or more items do not belong to this company.';
  end if;

  -- Lock the stock rows of every item, always in item order, so two
  -- users posting the same items wait for each other instead of
  -- overselling or deadlocking.
  insert into stock_ledger (company_id, item_id, qty_units, stock_value)
  select p_company_id, u, 0, 0 from unnest(v_ids) u
  on conflict (company_id, item_id) do nothing;

  perform 1
  from stock_ledger
  where company_id = p_company_id and item_id = any(v_ids)
  order by item_id
  for update;

  v_prefix := case p_type
                when 'GRN'   then 'GRN'
                when 'ISS'   then 'ISS'
                when 'RET'   then 'RET'
                when 'SALE'  then 'SAL'
                when 'AJUST' then 'ADJ'
              end;
  v_doc := next_doc_no(v_prefix, p_date);

  insert into tx_header (doc_no, company_id, date, type, rep_id, remarks,
                         posted_by, locked, status)
  values (v_doc, p_company_id, p_date, p_type, v_rep_id, v_remarks,
          v_uid, true, 'active');

  for v_line in
    select *
    from jsonb_to_recordset(p_lines)
      as x(item_id int, qty_cases int, qty_units int, free_units int,
           disc_pct numeric, disc_amt numeric)
    order by x.item_id
  loop
    select id, name, units_per_case, unit_price, active
      into v_item
    from items where id = v_line.item_id;

    v_cases := coalesce(v_line.qty_cases, 0);
    v_units := coalesce(v_line.qty_units, 0);

    -- Free units and discounts exist only on goods received.
    if p_type = 'GRN' then
      v_free  := coalesce(v_line.free_units, 0);
      v_discp := coalesce(v_line.disc_pct, 0);
      v_disca := coalesce(v_line.disc_amt, 0);
    else
      v_free := 0; v_discp := 0; v_disca := 0;
    end if;

    if p_type = 'AJUST' then
      if not ((v_cases >= 0 and v_units >= 0) or (v_cases <= 0 and v_units <= 0)) then
        raise exception 'Adjustment for "%": cases and units must have the same sign.', v_item.name;
      end if;
    elsif v_cases < 0 or v_units < 0 or v_free < 0 then
      raise exception 'Quantity for "%" cannot be negative.', v_item.name;
    end if;

    if v_discp < 0 or v_discp > 100 or v_disca < 0 then
      raise exception 'Discount for "%" is not valid.', v_item.name;
    end if;

    if p_type in ('GRN','ISS') and not v_item.active then
      raise exception '"%" is inactive.', v_item.name;
    end if;

    -- Units per case and price are taken from the item NOW and stored
    -- on the line. Later edits to the item do not change this document.
    v_total := v_cases * v_item.units_per_case + v_units + v_free;

    if v_total = 0 then
      raise exception 'Quantity for "%" is zero.', v_item.name;
    end if;
    if v_total * v_item.unit_price * (1 - v_discp / 100.0) - v_disca < 0 and p_type = 'GRN' then
      raise exception 'Discount for "%" is larger than the line value.', v_item.name;
    end if;

    case p_type
      when 'GRN'   then perform apply_movement(p_company_id, v_item.id, null,      v_total,  0);
      when 'ISS'   then perform apply_movement(p_company_id, v_item.id, v_rep_id, -v_total,  v_total);
      when 'RET'   then perform apply_movement(p_company_id, v_item.id, v_rep_id,  v_total, -v_total);
      when 'SALE'  then perform apply_movement(p_company_id, v_item.id, v_rep_id,  0,       -v_total);
      when 'AJUST' then perform apply_movement(p_company_id, v_item.id, null,      v_total,  0);
    end case;

    insert into tx_lines (doc_no, item_id, qty_cases, qty_units, free_units,
                          disc_pct, disc_amt, unit_price, units_per_case, total_units)
    values (v_doc, v_item.id, v_cases, v_units, v_free,
            v_discp, v_disca, v_item.unit_price, v_item.units_per_case, v_total);
  end loop;

  return v_doc;
end $$;


-- ---------------------------------------------------------------------
-- 6. REVERSE A TRANSACTION (admin)
--    Posted documents are never edited or deleted. A mistake is fixed
--    by a REV document that applies the opposite movement and marks
--    the original as reversed. Both stay in the history.
-- ---------------------------------------------------------------------

create or replace function public.reverse_transaction(
  p_doc_no text,
  p_reason text
) returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'Asia/Colombo')::date;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_h      tx_header%rowtype;
  v_rev    text;
  v_ids    int[];
  v_line   record;
begin
  if v_uid is null then
    raise exception 'You are not signed in.' using errcode = '28000';
  end if;

  select * into v_h from tx_header where doc_no = p_doc_no for update;
  if not found or not can_access_company(v_h.company_id) then
    raise exception 'Document % not found.', p_doc_no;
  end if;
  if not is_admin() then
    raise exception 'Only an admin can reverse a transaction.' using errcode = '42501';
  end if;
  if v_h.type = 'REV' then
    raise exception 'A reversal cannot be reversed. Post the document again instead.';
  end if;
  if v_h.status <> 'active' then
    raise exception 'Document % is already reversed.', p_doc_no;
  end if;
  if v_reason is null then
    raise exception 'Give a reason for the reversal.';
  end if;

  select array_agg(distinct item_id order by item_id) into v_ids
  from tx_lines where doc_no = p_doc_no;

  if v_ids is not null then
    insert into stock_ledger (company_id, item_id, qty_units, stock_value)
    select v_h.company_id, u, 0, 0 from unnest(v_ids) u
    on conflict (company_id, item_id) do nothing;

    perform 1
    from stock_ledger
    where company_id = v_h.company_id and item_id = any(v_ids)
    order by item_id
    for update;
  end if;

  v_rev := next_doc_no('REV', v_today);

  insert into tx_header (doc_no, company_id, date, type, rep_id, remarks,
                         posted_by, locked, status, reversal_of)
  values (v_rev, v_h.company_id, v_today, 'REV', v_h.rep_id,
          'Reversal of ' || p_doc_no || ': ' || v_reason,
          v_uid, true, 'active', p_doc_no);

  for v_line in
    select * from tx_lines where doc_no = p_doc_no order by item_id, id
  loop
    -- Opposite of section 5.
    case v_h.type
      when 'GRN'   then perform apply_movement(v_h.company_id, v_line.item_id, null,      -v_line.total_units,  0);
      when 'ISS'   then perform apply_movement(v_h.company_id, v_line.item_id, v_h.rep_id, v_line.total_units, -v_line.total_units);
      when 'RET'   then perform apply_movement(v_h.company_id, v_line.item_id, v_h.rep_id,-v_line.total_units,  v_line.total_units);
      when 'SALE'  then perform apply_movement(v_h.company_id, v_line.item_id, v_h.rep_id, 0,                   v_line.total_units);
      when 'AJUST' then perform apply_movement(v_h.company_id, v_line.item_id, null,      -v_line.total_units,  0);
    end case;

    -- Copy of the original lines, kept on the REV document for the record.
    insert into tx_lines (doc_no, item_id, qty_cases, qty_units, free_units,
                          disc_pct, disc_amt, unit_price, units_per_case, total_units)
    values (v_rev, v_line.item_id, v_line.qty_cases, v_line.qty_units, v_line.free_units,
            v_line.disc_pct, v_line.disc_amt, v_line.unit_price,
            v_line.units_per_case, v_line.total_units);
  end loop;

  update tx_header
     set status = 'reversed', reversed_by = v_rev
   where doc_no = p_doc_no;

  return v_rev;
end $$;


-- ---------------------------------------------------------------------
-- 7. TRIGGERS
-- ---------------------------------------------------------------------

-- Stock is now moved by post_transaction(), not by a trigger on tx_lines.
-- (The old function update_stock_on_transaction is kept for rollback.)
drop trigger if exists trg_update_stock on public.tx_lines;

-- Generic audit trigger: who changed what, with before and after values.
create or replace function public.audit_row_change()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_row jsonb;
begin
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
  if tg_op = 'UPDATE' and v_old = v_new then
    return new;
  end if;
  v_row := coalesce(v_new, v_old);

  insert into audit_log (company_id, user_id, action, table_name, record_id, old_data, new_data)
  values (
    case when tg_table_name = 'companies'
         then (v_row->>'id')::int
         else (v_row->>'company_id')::int end,
    auth.uid(),
    tg_op,
    tg_table_name,
    v_row->>(tg_argv[0]),
    v_old,
    v_new
  );
  return coalesce(new, old);
end $$;

drop trigger if exists trg_audit_tx on public.tx_header;   -- replaced below

drop trigger if exists trg_audit_tx_header on public.tx_header;
create trigger trg_audit_tx_header
  after insert or update or delete on public.tx_header
  for each row execute function public.audit_row_change('doc_no');

drop trigger if exists trg_audit_items on public.items;
create trigger trg_audit_items
  after insert or update or delete on public.items
  for each row execute function public.audit_row_change('id');

drop trigger if exists trg_audit_sales_reps on public.sales_reps;
create trigger trg_audit_sales_reps
  after insert or update or delete on public.sales_reps
  for each row execute function public.audit_row_change('id');

drop trigger if exists trg_audit_companies on public.companies;
create trigger trg_audit_companies
  after insert or update on public.companies
  for each row execute function public.audit_row_change('id');

drop trigger if exists trg_audit_user_profiles on public.user_profiles;
create trigger trg_audit_user_profiles
  after insert or update on public.user_profiles
  for each row execute function public.audit_row_change('id');

drop trigger if exists trg_audit_user_company_access on public.user_company_access;
create trigger trg_audit_user_company_access
  after insert or delete on public.user_company_access
  for each row execute function public.audit_row_change('user_id');

drop trigger if exists trg_audit_opening_balances on public.opening_balances;
create trigger trg_audit_opening_balances
  after insert or delete on public.opening_balances
  for each row execute function public.audit_row_change('id');

-- An item or rep cannot be moved to another company: its documents and
-- balances belong to the company it was created in.
create or replace function public.prevent_company_change()
returns trigger
language plpgsql set search_path = public
as $$
begin
  if new.company_id is distinct from old.company_id then
    raise exception 'This record cannot be moved to another company.';
  end if;
  return new;
end $$;

drop trigger if exists trg_items_company_fixed on public.items;
create trigger trg_items_company_fixed
  before update on public.items
  for each row execute function public.prevent_company_change();

drop trigger if exists trg_reps_company_fixed on public.sales_reps;
create trigger trg_reps_company_fixed
  before update on public.sales_reps
  for each row execute function public.prevent_company_change();

-- Keep stock_ledger.stock_value (quantity x current price) in step when
-- an item's price changes. Posted documents are not touched.
create or replace function public.refresh_stock_value()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.unit_price is distinct from old.unit_price then
    update stock_ledger
       set stock_value = qty_units * new.unit_price
     where item_id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists trg_items_refresh_stock_value on public.items;
create trigger trg_items_refresh_stock_value
  after update on public.items
  for each row execute function public.refresh_stock_value();

-- The system must always have at least one admin.
create or replace function public.guard_last_admin()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if old.role = 'admin'
     and (tg_op = 'DELETE' or new.role <> 'admin')
     and not exists (select 1 from user_profiles
                     where role = 'admin' and id <> old.id) then
    raise exception 'At least one admin is required.';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_guard_last_admin on public.user_profiles;
create trigger trg_guard_last_admin
  before update or delete on public.user_profiles
  for each row execute function public.guard_last_admin();


-- ---------------------------------------------------------------------
-- 8. ROW LEVEL SECURITY
--    Every existing policy was "using (true)": any signed-in user could
--    read, change or delete anything, including making themselves admin.
--    All of them are dropped and replaced.
--
--    Ledgers, documents and the audit log have NO write policy at all.
--    They can only be written by the functions above.
-- ---------------------------------------------------------------------

do $$
declare r record;
begin
  for r in
    select tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('app_settings','audit_log','companies','daily_snapshots',
                        'items','rep_ledger','sales_reps','stock_ledger',
                        'tx_header','tx_lines','user_profiles',
                        'user_company_access','doc_counters','opening_balances')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

alter table public.app_settings        enable row level security;
alter table public.audit_log           enable row level security;
alter table public.companies           enable row level security;
alter table public.daily_snapshots     enable row level security;
alter table public.items               enable row level security;
alter table public.rep_ledger          enable row level security;
alter table public.sales_reps          enable row level security;
alter table public.stock_ledger        enable row level security;
alter table public.tx_header           enable row level security;
alter table public.tx_lines            enable row level security;
alter table public.user_profiles       enable row level security;
alter table public.user_company_access enable row level security;
alter table public.doc_counters        enable row level security;
alter table public.opening_balances    enable row level security;

-- companies
create policy companies_select on public.companies for select to authenticated
  using (id in (select public.accessible_company_ids()));
create policy companies_insert on public.companies for insert to authenticated
  with check (public.is_admin());
create policy companies_update on public.companies for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- items
create policy items_select on public.items for select to authenticated
  using (company_id in (select public.accessible_company_ids()));
create policy items_insert on public.items for insert to authenticated
  with check (public.is_admin());
create policy items_update on public.items for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- sales_reps
create policy reps_select on public.sales_reps for select to authenticated
  using (company_id in (select public.accessible_company_ids()));
create policy reps_insert on public.sales_reps for insert to authenticated
  with check (public.is_admin());
create policy reps_update on public.sales_reps for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ledgers and documents: read only
create policy stock_select on public.stock_ledger for select to authenticated
  using (company_id in (select public.accessible_company_ids()));
create policy rep_ledger_select on public.rep_ledger for select to authenticated
  using (company_id in (select public.accessible_company_ids()));
create policy tx_header_select on public.tx_header for select to authenticated
  using (company_id in (select public.accessible_company_ids()));
create policy tx_lines_select on public.tx_lines for select to authenticated
  using (exists (select 1 from public.tx_header h where h.doc_no = tx_lines.doc_no));
create policy snapshots_select on public.daily_snapshots for select to authenticated
  using (company_id in (select public.accessible_company_ids()));
create policy opening_select on public.opening_balances for select to authenticated
  using (company_id in (select public.accessible_company_ids()));

-- audit log: admins read, nobody writes directly
create policy audit_log_select on public.audit_log for select to authenticated
  using (public.is_admin());

-- settings
create policy settings_select on public.app_settings for select to authenticated
  using (company_id in (select public.accessible_company_ids()));
create policy settings_insert on public.app_settings for insert to authenticated
  with check (public.is_admin());
create policy settings_update on public.app_settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- users: everyone signed in can see names (needed for "posted by");
-- only admins can change a profile, so nobody can promote themselves.
create policy user_profiles_select on public.user_profiles for select to authenticated
  using (true);
create policy user_profiles_update on public.user_profiles for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy uca_select on public.user_company_access for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
create policy uca_insert on public.user_company_access for insert to authenticated
  with check (public.is_admin());
create policy uca_delete on public.user_company_access for delete to authenticated
  using (public.is_admin());

-- Table privileges (second line of defence behind the policies).
revoke all on all tables in schema public from anon;
revoke insert, update, delete, truncate
  on public.tx_header, public.tx_lines, public.stock_ledger, public.rep_ledger,
     public.audit_log, public.doc_counters, public.daily_snapshots,
     public.opening_balances
  from authenticated;
revoke all on public.doc_counters from authenticated;
grant select, insert, delete on public.user_company_access to authenticated;


-- ---------------------------------------------------------------------
-- 9. REPORTING VIEWS
--    security_invoker = the view obeys the caller's RLS. (The four old
--    views were flagged "Unrestricted" because they did not.)
--    Reversed documents and their REV documents are excluded from every
--    total: together they net to zero.
-- ---------------------------------------------------------------------

-- Dropped first so a re-run can change their columns.
drop view if exists public.v_tx_lines, public.v_tx_documents, public.v_stock,
                    public.v_rep_holdings, public.v_rep_summary,
                    public.v_reconciliation, public.v_opening_balances;

create or replace view public.v_tx_lines
with (security_invoker = true) as
select
  l.id             as line_id,
  h.doc_no,
  h.company_id,
  h.date,
  h.type,
  h.status,
  h.rep_id,
  r.name           as rep_name,
  h.remarks,
  p.full_name      as posted_by_name,
  h.created_at,
  l.item_id,
  i.name           as item_name,
  l.qty_cases,
  l.qty_units,
  l.free_units,
  l.units_per_case,
  l.total_units,
  l.unit_price,
  l.disc_pct,
  l.disc_amt,
  round(l.total_units * l.unit_price, 2)                                         as gross_value,
  round(l.total_units * l.unit_price * (1 - l.disc_pct / 100.0) - l.disc_amt, 2) as line_value
from public.tx_lines l
join public.tx_header h          on h.doc_no = l.doc_no
join public.items i              on i.id = l.item_id
left join public.sales_reps r    on r.id = h.rep_id
left join public.user_profiles p on p.id = h.posted_by;

create or replace view public.v_tx_documents
with (security_invoker = true) as
select
  h.doc_no,
  h.company_id,
  h.date,
  h.type,
  h.status,
  h.rep_id,
  r.name                        as rep_name,
  h.remarks,
  h.posted_by,
  p.full_name                   as posted_by_name,
  h.created_at,
  h.reversed_by,
  h.reversal_of,
  coalesce(a.line_count, 0)     as line_count,
  coalesce(a.total_units, 0)    as total_units,
  coalesce(a.gross_value, 0)    as gross_value,
  coalesce(a.doc_value, 0)      as doc_value,
  coalesce(a.item_ids, '{}')    as item_ids
from public.tx_header h
left join public.sales_reps r    on r.id = h.rep_id
left join public.user_profiles p on p.id = h.posted_by
left join lateral (
  select count(*)::int                                       as line_count,
         sum(l.total_units)::int                             as total_units,
         sum(round(l.total_units * l.unit_price, 2))         as gross_value,
         sum(round(l.total_units * l.unit_price * (1 - l.disc_pct / 100.0) - l.disc_amt, 2)) as doc_value,
         array_agg(distinct l.item_id)                       as item_ids
  from public.tx_lines l
  where l.doc_no = h.doc_no
) a on true;

create or replace view public.v_stock
with (security_invoker = true) as
select
  i.company_id,
  i.id                                                             as item_id,
  i.name                                                           as item_name,
  i.units_per_case,
  i.unit_price,
  i.active,
  coalesce(s.qty_units, 0)                                         as qty_units,
  round(coalesce(s.qty_units, 0)::numeric / nullif(i.units_per_case, 0), 2) as qty_cases,
  round(coalesce(s.qty_units, 0) * i.unit_price, 2)                as stock_value,
  (coalesce(s.qty_units, 0) < 2 * i.units_per_case)                as low_stock,
  s.last_updated
from public.items i
left join public.stock_ledger s
       on s.item_id = i.id and s.company_id = i.company_id;

create or replace view public.v_rep_holdings
with (security_invoker = true) as
select
  rl.company_id,
  rl.rep_id,
  r.name                                  as rep_name,
  rl.item_id,
  i.name                                  as item_name,
  i.units_per_case,
  i.unit_price,
  rl.qty_units_held,
  round(rl.qty_units_held * i.unit_price, 2) as held_value,
  rl.last_updated
from public.rep_ledger rl
join public.sales_reps r on r.id = rl.rep_id
join public.items i      on i.id = rl.item_id
where rl.qty_units_held <> 0;

create or replace view public.v_rep_summary
with (security_invoker = true) as
select
  r.company_id,
  r.id                              as rep_id,
  r.name                            as rep_name,
  r.active,
  coalesce(t.issued_units, 0)       as issued_units,
  coalesce(t.returned_units, 0)     as returned_units,
  coalesce(t.sold_units, 0)         as sold_units,
  coalesce(t.issued_value, 0)       as issued_value,
  coalesce(t.returned_value, 0)     as returned_value,
  coalesce(t.sold_value, 0)         as sold_value,
  coalesce(hd.item_count, 0)        as item_count,
  coalesce(hd.held_units, 0)        as held_units,
  coalesce(hd.held_value, 0)        as held_value
from public.sales_reps r
left join (
  select h.rep_id,
         sum(l.total_units) filter (where h.type = 'ISS')::int                       as issued_units,
         sum(l.total_units) filter (where h.type = 'RET')::int                       as returned_units,
         sum(l.total_units) filter (where h.type = 'SALE')::int                      as sold_units,
         sum(round(l.total_units * l.unit_price, 2)) filter (where h.type = 'ISS')   as issued_value,
         sum(round(l.total_units * l.unit_price, 2)) filter (where h.type = 'RET')   as returned_value,
         sum(round(l.total_units * l.unit_price, 2)) filter (where h.type = 'SALE')  as sold_value
  from public.tx_lines l
  join public.tx_header h on h.doc_no = l.doc_no
  where h.status = 'active' and h.type in ('ISS','RET','SALE')
  group by h.rep_id
) t on t.rep_id = r.id
left join (
  select rl.rep_id,
         count(*)::int                                   as item_count,
         sum(rl.qty_units_held)::int                     as held_units,
         sum(round(rl.qty_units_held * i.unit_price, 2)) as held_value
  from public.rep_ledger rl
  join public.items i on i.id = rl.item_id
  where rl.qty_units_held <> 0
  group by rl.rep_id
) hd on hd.rep_id = r.id;

-- Reconciliation, one row per item. Two independent checks:
--   warehouse : opening + GRN + adjustments - issued + returned = stock_ledger
--   reps      : opening + issued - returned - sold              = rep_ledger
create or replace view public.v_reconciliation
with (security_invoker = true) as
select
  i.company_id,
  i.id                                as item_id,
  i.name                              as item_name,
  i.units_per_case,
  i.unit_price,
  i.active,
  coalesce(m.grn_units, 0)            as grn_units,
  coalesce(m.adjust_units, 0)         as adjust_units,
  coalesce(m.issued_units, 0)         as issued_units,
  coalesce(m.returned_units, 0)       as returned_units,
  coalesce(m.sold_units, 0)           as sold_units,
  coalesce(m.grn_value, 0)            as grn_value,
  coalesce(m.issued_value, 0)         as issued_value,
  coalesce(m.returned_value, 0)       as returned_value,
  coalesce(m.sold_value, 0)           as sold_value,
  coalesce(ob.stock_units, 0)         as opening_stock_units,
  coalesce(ob.rep_units, 0)           as opening_rep_units,
  coalesce(s.qty_units, 0)            as stock_units,
  x.expected_stock_units,
  coalesce(s.qty_units, 0) - x.expected_stock_units  as stock_variance,
  coalesce(rp.rep_units, 0)           as rep_units,
  x.expected_rep_units,
  coalesce(rp.rep_units, 0) - x.expected_rep_units   as rep_variance,
  round(coalesce(s.qty_units, 0) * i.unit_price, 2)  as stock_value,
  round(coalesce(rp.rep_units, 0) * i.unit_price, 2) as rep_value
from public.items i
left join (
  select l.item_id,
         sum(l.total_units) filter (where h.type = 'GRN')::int    as grn_units,
         sum(l.total_units) filter (where h.type = 'AJUST')::int  as adjust_units,
         sum(l.total_units) filter (where h.type = 'ISS')::int    as issued_units,
         sum(l.total_units) filter (where h.type = 'RET')::int    as returned_units,
         sum(l.total_units) filter (where h.type = 'SALE')::int   as sold_units,
         sum(round(l.total_units * l.unit_price, 2)) filter (where h.type = 'GRN')  as grn_value,
         sum(round(l.total_units * l.unit_price, 2)) filter (where h.type = 'ISS')  as issued_value,
         sum(round(l.total_units * l.unit_price, 2)) filter (where h.type = 'RET')  as returned_value,
         sum(round(l.total_units * l.unit_price, 2)) filter (where h.type = 'SALE') as sold_value
  from public.tx_lines l
  join public.tx_header h on h.doc_no = l.doc_no
  where h.status = 'active' and h.type <> 'REV'
  group by l.item_id
) m on m.item_id = i.id
left join public.stock_ledger s
       on s.item_id = i.id and s.company_id = i.company_id
left join (
  select item_id, sum(qty_units_held)::int as rep_units
  from public.rep_ledger
  group by item_id
) rp on rp.item_id = i.id
left join (
  select item_id,
         sum(units) filter (where rep_id is null)::int     as stock_units,
         sum(units) filter (where rep_id is not null)::int as rep_units
  from public.opening_balances
  group by item_id
) ob on ob.item_id = i.id
cross join lateral (
  select
    coalesce(ob.stock_units, 0) + coalesce(m.grn_units, 0) + coalesce(m.adjust_units, 0)
      - coalesce(m.issued_units, 0) + coalesce(m.returned_units, 0)  as expected_stock_units,
    coalesce(ob.rep_units, 0) + coalesce(m.issued_units, 0)
      - coalesce(m.returned_units, 0) - coalesce(m.sold_units, 0)    as expected_rep_units
) x;

create or replace view public.v_opening_balances
with (security_invoker = true) as
select o.id, o.company_id, o.item_id, i.name as item_name,
       o.rep_id, r.name as rep_name, o.units, o.reason, o.created_at
from public.opening_balances o
join public.items i           on i.id = o.item_id
left join public.sales_reps r on r.id = o.rep_id;

-- Totals for the Transactions screen (all matching rows, not one page).
create or replace function public.tx_summary(
  p_company_id int,
  p_from       date default null,
  p_to         date default null,
  p_type       text default null,
  p_rep_id     int  default null,
  p_item_id    int  default null,
  p_doc_no     text default null,
  p_status     text default null
) returns table (
  doc_count      bigint,
  grn_value      numeric,
  issued_value   numeric,
  returned_value numeric,
  sold_value     numeric
)
language sql stable security invoker set search_path = public
as $$
  select
    count(*),
    coalesce(sum(d.doc_value) filter (where d.type = 'GRN'  and d.status = 'active'), 0),
    coalesce(sum(d.doc_value) filter (where d.type = 'ISS'  and d.status = 'active'), 0),
    coalesce(sum(d.doc_value) filter (where d.type = 'RET'  and d.status = 'active'), 0),
    coalesce(sum(d.doc_value) filter (where d.type = 'SALE' and d.status = 'active'), 0)
  from v_tx_documents d
  where d.company_id = p_company_id
    and (p_from    is null or d.date >= p_from)
    and (p_to      is null or d.date <= p_to)
    and (p_type    is null or d.type = p_type)
    and (p_rep_id  is null or d.rep_id = p_rep_id)
    and (p_item_id is null or d.item_ids @> array[p_item_id])
    and (p_doc_no  is null or strpos(lower(d.doc_no), lower(p_doc_no)) > 0)
    and (p_status  is null or d.status = p_status)
$$;

-- The four old views stay for now, but obey RLS from here on.
do $$
declare v text;
begin
  foreach v in array array['v_active_transactions','v_financial_summary',
                           'v_rep_performance','v_stock_summary']
  loop
    if to_regclass('public.' || v) is not null then
      execute format('alter view public.%I set (security_invoker = true)', v);
    end if;
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- 10. CUTOVER TOOLS (SQL Editor only; not callable through the API)
--     The old system let balances drift from the documents in three
--     ways: a reversal that did not take stock off the rep, a return
--     posted against an empty rep balance, and edits made outside any
--     document. These functions find such rows and settle each one by
--     an explicit decision. They are used by 02_cutover_corrections.sql.
-- ---------------------------------------------------------------------

-- Every balance that disagrees with the documents, per warehouse item
-- and per rep and item. Empty result = everything reconciles.
create or replace function public.cutover_differences()
returns table (
  kind text, company_id int, company text, rep_id int, rep text,
  item_id int, item text, ledger int, expected int, diff int,
  reversed_issue_units int
)
language sql stable security definer set search_path = public
as $$
  with mv as (
    select h.type, h.status, h.rep_id, l.item_id, l.total_units
    from tx_lines l
    join tx_header h on h.doc_no = l.doc_no
  ),
  wh as (
    select item_id,
           sum(case type when 'GRN'   then total_units
                         when 'AJUST' then total_units
                         when 'ISS'   then -total_units
                         when 'RET'   then total_units
                         else 0 end)::int as units
    from mv
    where status = 'active' and type <> 'REV'
    group by item_id
  ),
  wh_open as (
    select item_id, sum(units)::int as units
    from opening_balances where rep_id is null group by item_id
  ),
  rp as (
    select rep_id, item_id,
           sum(case when status = 'active' then
                 case type when 'ISS' then total_units else -total_units end
               else 0 end)::int                                           as units,
           sum(case when status = 'reversed' and type = 'ISS'
                    then total_units else 0 end)::int                     as rev_iss
    from mv
    where rep_id is not null and type in ('ISS','RET','SALE')
    group by rep_id, item_id
  ),
  rp_open as (
    select rep_id, item_id, sum(units)::int as units
    from opening_balances where rep_id is not null group by rep_id, item_id
  ),
  rp_keys as (
    select rep_id, item_id from rep_ledger
    union select rep_id, item_id from rp
    union select rep_id, item_id from rp_open
  )
  select 'warehouse', i.company_id, c.name, null::int, null::text, i.id, i.name,
         coalesce(s.qty_units, 0),
         coalesce(wh.units, 0) + coalesce(wo.units, 0),
         coalesce(s.qty_units, 0) - (coalesce(wh.units, 0) + coalesce(wo.units, 0)),
         0
  from items i
  join companies c on c.id = i.company_id
  left join stock_ledger s on s.item_id = i.id and s.company_id = i.company_id
  left join wh         on wh.item_id = i.id
  left join wh_open wo on wo.item_id = i.id
  where coalesce(s.qty_units, 0) <> coalesce(wh.units, 0) + coalesce(wo.units, 0)

  union all
  select 'rep', i.company_id, c.name, r.id, r.name, i.id, i.name,
         coalesce(rl.qty_units_held, 0),
         coalesce(rp.units, 0) + coalesce(ro.units, 0),
         coalesce(rl.qty_units_held, 0) - (coalesce(rp.units, 0) + coalesce(ro.units, 0)),
         coalesce(rp.rev_iss, 0)
  from rp_keys k
  join items i      on i.id = k.item_id
  join companies c  on c.id = i.company_id
  join sales_reps r on r.id = k.rep_id
  left join rep_ledger rl on rl.rep_id = k.rep_id and rl.item_id = k.item_id
  left join rp            on rp.rep_id = k.rep_id and rp.item_id = k.item_id
  left join rp_open ro    on ro.rep_id = k.rep_id and ro.item_id = k.item_id
  where coalesce(rl.qty_units_held, 0) <> coalesce(rp.units, 0) + coalesce(ro.units, 0)
$$;

-- Rule with no judgement in it: where a rep balance is too high by
-- exactly the quantity of that rep's REVERSED issues, the reversal
-- restored the warehouse but never took the stock off the rep.
-- The documents are right; the rep balance is brought down to them.
create or replace function public.cutover_fix_reversed_issues()
returns int
language plpgsql security definer set search_path = public
as $$
declare
  r record;
  n int := 0;
begin
  for r in
    select * from cutover_differences() d
    where d.kind = 'rep' and d.diff > 0
      and d.diff = d.reversed_issue_units and d.expected >= 0
  loop
    update rep_ledger
       set qty_units_held = r.expected, last_updated = now()
     where rep_id = r.rep_id and item_id = r.item_id;

    insert into audit_log (company_id, user_id, action, table_name, record_id, old_data, new_data)
    values (r.company_id, auth.uid(), 'UPDATE', 'rep_ledger', r.rep || ' / ' || r.item,
            jsonb_build_object('qty_units_held', r.ledger),
            jsonb_build_object('qty_units_held', r.expected,
              'reason', 'Cutover: an issue to this rep was reversed but the rep balance had not been reduced.'));
    n := n + 1;
  end loop;
  return n;
end $$;

-- The opposite choice for the same rows: leave the rep balance exactly
-- as it is and record the gap as an opening difference.
create or replace function public.cutover_keep_reversed_issues()
returns int
language plpgsql security definer set search_path = public
as $$
declare
  r record;
  n int := 0;
begin
  for r in
    select * from cutover_differences() d
    where d.kind = 'rep' and d.diff > 0 and d.diff = d.reversed_issue_units
  loop
    insert into opening_balances (company_id, item_id, rep_id, units, reason)
    values (r.company_id, r.item_id, r.rep_id, r.diff,
            'Reversed issue: the old system returned the stock to the warehouse but did not reduce the rep balance. Balance kept as it was.');
    n := n + 1;
  end loop;
  return n;
end $$;

-- One decision for one balance.
--   p_rep null        -> the warehouse balance of the item
--   'use_documents'   -> the balance is wrong: set it to what the documents say
--   'keep_ledger'     -> the balance is right: record the gap as an opening difference
-- Calling it again for the same balance replaces the earlier decision.
create or replace function public.cutover_resolve(
  p_company text,   -- may be null if the item name exists in one company only
  p_item    text,
  p_rep     text,
  p_action  text,
  p_reason  text
) returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_item   record;
  v_rep_id int;
  v_n      int;
  v_d      record;
  v_who    text;
begin
  if p_action is null or p_action not in ('use_documents','keep_ledger') then
    raise exception 'Action must be use_documents or keep_ledger, got "%".', p_action;
  end if;
  if v_reason is null then
    raise exception 'A reason is required.';
  end if;

  select count(*) into v_n
  from items i join companies c on c.id = i.company_id
  where btrim(i.name) = btrim(p_item)
    and (p_company is null or btrim(c.name) = btrim(p_company));
  if v_n <> 1 then
    raise exception 'Item "%" (company %): % matches, expected exactly 1.',
      p_item, coalesce(p_company, 'any'), v_n;
  end if;
  select i.id, i.company_id, i.name, i.unit_price into v_item
  from items i join companies c on c.id = i.company_id
  where btrim(i.name) = btrim(p_item)
    and (p_company is null or btrim(c.name) = btrim(p_company));

  if p_rep is not null then
    select count(*), min(id) into v_n, v_rep_id
    from sales_reps
    where company_id = v_item.company_id and btrim(name) = btrim(p_rep);
    if v_n <> 1 then
      raise exception 'Rep "%" in the company of "%": % matches, expected exactly 1.',
        p_rep, v_item.name, v_n;
    end if;
  end if;
  v_who := coalesce(p_rep, 'warehouse') || ' / ' || v_item.name;

  -- Drop any earlier decision for this balance, then look at it afresh.
  delete from opening_balances
  where item_id = v_item.id and rep_id is not distinct from v_rep_id;

  select * into v_d
  from cutover_differences() d
  where d.item_id = v_item.id and d.rep_id is not distinct from v_rep_id;

  if not found then
    return v_who || ': already balanced, nothing to do';
  end if;

  if p_action = 'keep_ledger' then
    insert into opening_balances (company_id, item_id, rep_id, units, reason)
    values (v_item.company_id, v_item.id, v_rep_id, v_d.diff, v_reason);
    return format('%s: balance kept at %s, opening difference %s recorded',
                  v_who, v_d.ledger, v_d.diff);
  end if;

  -- use_documents
  if v_d.expected < 0 then
    raise exception '%: the documents give %, and a balance cannot be below zero. Use keep_ledger.',
      v_who, v_d.expected;
  end if;

  if v_rep_id is null then
    insert into stock_ledger (company_id, item_id, qty_units, stock_value)
    values (v_item.company_id, v_item.id, v_d.expected, v_d.expected * v_item.unit_price)
    on conflict (company_id, item_id)
    do update set qty_units = excluded.qty_units, stock_value = excluded.stock_value, last_updated = now();
  else
    insert into rep_ledger (company_id, rep_id, item_id, qty_units_held)
    values (v_item.company_id, v_rep_id, v_item.id, v_d.expected)
    on conflict (company_id, rep_id, item_id)
    do update set qty_units_held = excluded.qty_units_held, last_updated = now();
  end if;

  insert into audit_log (company_id, user_id, action, table_name, record_id, old_data, new_data)
  values (v_item.company_id, auth.uid(), 'UPDATE',
          case when v_rep_id is null then 'stock_ledger' else 'rep_ledger' end,
          v_who,
          jsonb_build_object('units', v_d.ledger),
          jsonb_build_object('units', v_d.expected, 'reason', 'Cutover: ' || v_reason));

  return format('%s: balance changed from %s to %s', v_who, v_d.ledger, v_d.expected);
end $$;


-- ---------------------------------------------------------------------
-- 11. FUNCTION PRIVILEGES
--     Supabase grants EXECUTE on new functions to anon and authenticated
--     by default. Take that away, then grant only what the app calls.
-- ---------------------------------------------------------------------

revoke all on function public.next_doc_no(text, date)                           from public, anon, authenticated;
revoke all on function public.apply_movement(int, int, int, int, int)           from public, anon, authenticated;
revoke all on function public.audit_row_change()                                from public, anon, authenticated;
revoke all on function public.prevent_company_change()                          from public, anon, authenticated;
revoke all on function public.refresh_stock_value()                             from public, anon, authenticated;
revoke all on function public.guard_last_admin()                                from public, anon, authenticated;
revoke all on function public.update_stock_on_transaction()                     from public, anon, authenticated;
revoke all on function public.cutover_differences()                             from public, anon, authenticated;
revoke all on function public.cutover_fix_reversed_issues()                     from public, anon, authenticated;
revoke all on function public.cutover_keep_reversed_issues()                    from public, anon, authenticated;
revoke all on function public.cutover_resolve(text, text, text, text, text)     from public, anon, authenticated;

revoke all on function public.post_transaction(int, text, date, int, text, jsonb) from public, anon;
revoke all on function public.reverse_transaction(text, text)                     from public, anon;
revoke all on function public.tx_summary(int, date, date, text, int, int, text, text) from public, anon;
revoke all on function public.is_admin()                                          from public, anon;
revoke all on function public.can_access_company(int)                             from public, anon;
revoke all on function public.accessible_company_ids()                            from public, anon;

grant execute on function public.post_transaction(int, text, date, int, text, jsonb) to authenticated;
grant execute on function public.reverse_transaction(text, text)                     to authenticated;
grant execute on function public.tx_summary(int, date, date, text, int, int, text, text) to authenticated;
grant execute on function public.is_admin()                                          to authenticated;
grant execute on function public.can_access_company(int)                             to authenticated;
grant execute on function public.accessible_company_ids()                            to authenticated;

-- Views: readable by signed-in users only (RLS still applies underneath).
revoke all on public.v_tx_lines, public.v_tx_documents, public.v_stock,
              public.v_rep_holdings, public.v_rep_summary, public.v_reconciliation,
              public.v_opening_balances
  from anon;
grant select on public.v_tx_lines, public.v_tx_documents, public.v_stock,
                public.v_rep_holdings, public.v_rep_summary, public.v_reconciliation,
                public.v_opening_balances
  to authenticated;

commit;

-- Tell the API layer to pick up the new functions and views immediately.
notify pgrst, 'reload schema';
