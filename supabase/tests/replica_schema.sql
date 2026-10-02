-- Rebuilds the schema as it exists in production BEFORE the migration,
-- on a plain local Postgres. Used only for testing 01_migration.sql.
-- Source: the schema dump taken from the live project on 2026-10-02.

-- ---- Supabase stand-ins ------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon')          then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role')  then create role service_role nologin bypassrls; end if;
end $$;

create schema auth;
create table auth.users (
  id uuid primary key,
  email text,
  raw_user_meta_data jsonb default '{}'::jsonb
);
-- Same definition Supabase ships: works with both claim formats.
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

grant usage on schema public, auth to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

-- ---- Tables -------------------------------------------------------------
create table public.companies (
  id serial primary key,
  name text not null unique,
  active bool not null default true,
  created_at timestamptz not null default now()
);

create table public.user_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  role text not null default 'user' check (role = any (array['admin','user'])),
  company_id int references public.companies(id),
  created_at timestamptz not null default now()
);

create table public.items (
  id serial primary key,
  company_id int not null references public.companies(id),
  name text not null,
  units_per_case int not null default 1,
  unit_price numeric not null default 0,
  active bool not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, name)
);

create table public.sales_reps (
  id serial primary key,
  company_id int not null references public.companies(id),
  name text not null,
  active bool not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, name)
);

create table public.stock_ledger (
  id serial primary key,
  company_id int not null references public.companies(id),
  item_id int not null references public.items(id),
  qty_units int not null default 0,
  stock_value numeric not null default 0,
  last_updated timestamptz not null default now(),
  unique (company_id, item_id)
);

create table public.rep_ledger (
  id serial primary key,
  company_id int not null references public.companies(id),
  rep_id int not null references public.sales_reps(id),
  item_id int not null references public.items(id),
  qty_units_held int not null default 0,
  last_updated timestamptz not null default now(),
  unique (company_id, rep_id, item_id)
);

create table public.tx_header (
  doc_no text primary key,
  company_id int not null references public.companies(id),
  date date not null,
  type text not null check (type = any (array['GRN','ISS','RET','AJUST','REV'])),
  rep_id int references public.sales_reps(id),
  remarks text,
  posted_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  locked bool not null default true,
  posted_by_profile uuid references public.user_profiles(id),
  status text not null default 'active' check (status = any (array['active','reversed'])),
  reversed_by text,
  reversal_of text
);

create table public.tx_lines (
  id serial primary key,
  doc_no text not null references public.tx_header(doc_no) on delete cascade,
  item_id int not null references public.items(id),
  qty_cases int not null default 0,
  qty_units int not null default 0,
  free_units int not null default 0,
  disc_pct numeric not null default 0,
  disc_amt numeric not null default 0,
  unit_price numeric not null default 0
);

create table public.audit_log (
  id serial primary key,
  company_id int references public.companies(id),
  user_id uuid references auth.users(id),
  action text not null,
  table_name text not null,
  record_id text,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now()
);

create table public.app_settings (
  id serial primary key,
  company_id int not null references public.companies(id),
  key text not null,
  value text not null,
  created_at timestamptz not null default now(),
  unique (company_id, key)
);

create table public.daily_snapshots (
  id serial primary key,
  company_id int not null references public.companies(id),
  snapshot_date date not null,
  item_id int not null references public.items(id),
  qty_units int not null default 0,
  stock_value numeric not null default 0,
  created_at timestamptz not null default now(),
  qty_cases numeric not null default 0,
  unique (company_id, snapshot_date, item_id)
);

-- ---- Functions (verbatim from the dump) ----------------------------------
CREATE OR REPLACE FUNCTION public.current_company_id()
 RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER
AS $function$
  SELECT company_id FROM user_profiles WHERE id = auth.uid()
$function$;

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.user_profiles (id, full_name, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
    'user'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'handle_new_user error: %', SQLERRM;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
AS $function$
  SELECT role = 'admin' FROM user_profiles WHERE id = auth.uid()
$function$;

CREATE OR REPLACE FUNCTION public.log_transaction_audit()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
AS $function$
BEGIN
  INSERT INTO audit_log (company_id, user_id, action, table_name, record_id, new_data)
  VALUES (NEW.company_id, NEW.posted_by, 'INSERT', 'tx_header', NEW.doc_no, row_to_json(NEW)::jsonb);
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_posted_by_profile()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
AS $function$
BEGIN
  NEW.posted_by_profile := NEW.posted_by;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_stock_on_transaction()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_type      TEXT;
  v_company   INT;
  v_rep       INT;
  v_total_units INT;
  v_upc       INT;
BEGIN
  SELECT type, company_id, rep_id
  INTO v_type, v_company, v_rep
  FROM tx_header WHERE doc_no = NEW.doc_no;

  SELECT units_per_case INTO v_upc FROM items WHERE id = NEW.item_id;

  v_total_units := (NEW.qty_cases * v_upc) + NEW.qty_units + NEW.free_units;

  IF v_type = 'GRN' THEN
    INSERT INTO stock_ledger (company_id, item_id, qty_units, stock_value)
    VALUES (v_company, NEW.item_id, v_total_units, v_total_units * NEW.unit_price)
    ON CONFLICT (company_id, item_id)
    DO UPDATE SET
      qty_units    = stock_ledger.qty_units + v_total_units,
      stock_value  = (stock_ledger.qty_units + v_total_units) *
                     (SELECT unit_price FROM items WHERE id = NEW.item_id),
      last_updated = NOW();

  ELSIF v_type = 'ISS' THEN
    UPDATE stock_ledger
    SET qty_units    = qty_units - v_total_units,
        stock_value  = GREATEST(qty_units - v_total_units, 0) *
                       (SELECT unit_price FROM items WHERE id = NEW.item_id),
        last_updated = NOW()
    WHERE company_id = v_company AND item_id = NEW.item_id;

    INSERT INTO rep_ledger (company_id, rep_id, item_id, qty_units_held)
    VALUES (v_company, v_rep, NEW.item_id, v_total_units)
    ON CONFLICT (company_id, rep_id, item_id)
    DO UPDATE SET
      qty_units_held = rep_ledger.qty_units_held + v_total_units,
      last_updated   = NOW();

  ELSIF v_type = 'RET' THEN
    UPDATE stock_ledger
    SET qty_units    = qty_units + v_total_units,
        stock_value  = (qty_units + v_total_units) *
                       (SELECT unit_price FROM items WHERE id = NEW.item_id),
        last_updated = NOW()
    WHERE company_id = v_company AND item_id = NEW.item_id;

    UPDATE rep_ledger
    SET qty_units_held = GREATEST(qty_units_held - v_total_units, 0),
        last_updated   = NOW()
    WHERE company_id = v_company AND rep_id = v_rep AND item_id = NEW.item_id;
  END IF;

  RETURN NEW;
END;
$function$;

-- ---- Triggers -----------------------------------------------------------
CREATE TRIGGER trg_audit_tx AFTER INSERT ON public.tx_header FOR EACH ROW EXECUTE FUNCTION log_transaction_audit();
CREATE TRIGGER trg_sync_posted_by BEFORE INSERT ON public.tx_header FOR EACH ROW EXECUTE FUNCTION sync_posted_by_profile();
CREATE TRIGGER trg_update_stock AFTER INSERT ON public.tx_lines FOR EACH ROW EXECUTE FUNCTION update_stock_on_transaction();
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ---- Views (from the dump) ------------------------------------------------
create view public.v_active_transactions as
 SELECT doc_no, company_id, date, type, rep_id, remarks, posted_by, created_at,
        locked, posted_by_profile, status, reversed_by, reversal_of
   FROM tx_header WHERE (status = 'active'::text);

create view public.v_financial_summary as
 SELECT c.name AS company,
    COALESCE(sum(CASE WHEN (h.type = 'GRN'::text) THEN (((((l.qty_cases * i.units_per_case) + l.qty_units) + l.free_units))::numeric * l.unit_price) ELSE (0)::numeric END), (0)::numeric) AS total_grn_value,
    COALESCE(sum(CASE WHEN (h.type = 'ISS'::text) THEN (((((l.qty_cases * i.units_per_case) + l.qty_units) + l.free_units))::numeric * l.unit_price) ELSE (0)::numeric END), (0)::numeric) AS total_issued_value,
    COALESCE(sum(CASE WHEN (h.type = 'RET'::text) THEN (((((l.qty_cases * i.units_per_case) + l.qty_units) + l.free_units))::numeric * l.unit_price) ELSE (0)::numeric END), (0)::numeric) AS total_return_value,
    (COALESCE(sum(CASE WHEN (h.type = 'ISS'::text) THEN (((((l.qty_cases * i.units_per_case) + l.qty_units) + l.free_units))::numeric * l.unit_price) ELSE (0)::numeric END), (0)::numeric)
     - COALESCE(sum(CASE WHEN (h.type = 'RET'::text) THEN (((((l.qty_cases * i.units_per_case) + l.qty_units) + l.free_units))::numeric * l.unit_price) ELSE (0)::numeric END), (0)::numeric)) AS net_sales_value,
    ( SELECT COALESCE(sum(sl.stock_value), (0)::numeric) FROM stock_ledger sl WHERE (sl.company_id = c.id)) AS available_stock_value
   FROM (((companies c
     LEFT JOIN tx_header h ON ((h.company_id = c.id)))
     LEFT JOIN tx_lines l ON ((l.doc_no = h.doc_no)))
     LEFT JOIN items i ON ((i.id = l.item_id)))
  GROUP BY c.id, c.name;

create view public.v_rep_performance as
 SELECT c.name AS company, r.name AS rep, i.name AS item, rl.qty_units_held,
    round(((rl.qty_units_held)::numeric / (NULLIF(i.units_per_case, 0))::numeric), 2) AS cases_held,
    ((rl.qty_units_held)::numeric * i.unit_price) AS held_value,
    to_char((rl.last_updated AT TIME ZONE 'Asia/Colombo'::text), 'YYYY-MM-DD HH24:MI:SS'::text) AS last_updated
   FROM (((rep_ledger rl
     JOIN sales_reps r ON ((r.id = rl.rep_id)))
     JOIN items i ON ((i.id = rl.item_id)))
     JOIN companies c ON ((c.id = rl.company_id)));

create view public.v_stock_summary as
 SELECT c.name AS company, i.name AS item, i.units_per_case, i.unit_price, sl.qty_units,
    round(((sl.qty_units)::numeric / (NULLIF(i.units_per_case, 0))::numeric), 2) AS qty_cases,
    sl.stock_value,
    CASE WHEN ((sl.qty_units / NULLIF(i.units_per_case, 0)) < 2) THEN true ELSE false END AS low_stock_alert,
    to_char((sl.last_updated AT TIME ZONE 'Asia/Colombo'::text), 'YYYY-MM-DD HH24:MI:SS'::text) AS last_updated
   FROM ((stock_ledger sl
     JOIN items i ON ((i.id = sl.item_id)))
     JOIN companies c ON ((c.id = sl.company_id)));

-- ---- RLS (from the dump: everything is "true") ---------------------------
alter table public.app_settings    enable row level security;
alter table public.audit_log       enable row level security;
alter table public.companies       enable row level security;
alter table public.daily_snapshots enable row level security;
alter table public.items           enable row level security;
alter table public.rep_ledger      enable row level security;
alter table public.sales_reps      enable row level security;
alter table public.stock_ledger    enable row level security;
alter table public.tx_header       enable row level security;
alter table public.tx_lines        enable row level security;
alter table public.user_profiles   enable row level security;

create policy settings_update on app_settings for update to authenticated using (true) with check (true);
create policy settings_insert on app_settings for insert to authenticated with check (true);
create policy settings_select on app_settings for select to authenticated using (true);
create policy audit_log_insert on audit_log for insert to authenticated with check (true);
create policy audit_log_select on audit_log for select to authenticated using (true);
create policy companies_select on companies for select to public using (true);
create policy companies_update on companies for update to authenticated using (true) with check (true);
create policy companies_insert on companies for insert to authenticated with check (true);
create policy snapshots_delete on daily_snapshots for delete to authenticated using (true);
create policy snapshots_update on daily_snapshots for update to authenticated using (true) with check (true);
create policy snapshots_insert on daily_snapshots for insert to authenticated with check (true);
create policy snapshots_select on daily_snapshots for select to authenticated using (true);
create policy items_delete on items for delete to authenticated using (true);
create policy items_select on items for select to authenticated using (true);
create policy items_insert on items for insert to authenticated with check (true);
create policy items_update on items for update to authenticated using (true) with check (true);
create policy rep_ledger_select on rep_ledger for select to authenticated using (true);
create policy rep_ledger_delete on rep_ledger for delete to authenticated using (true);
create policy rep_ledger_update on rep_ledger for update to authenticated using (true) with check (true);
create policy rep_ledger_insert on rep_ledger for insert to authenticated with check (true);
create policy reps_delete on sales_reps for delete to authenticated using (true);
create policy reps_update on sales_reps for update to authenticated using (true) with check (true);
create policy reps_insert on sales_reps for insert to authenticated with check (true);
create policy reps_select on sales_reps for select to authenticated using (true);
create policy stock_delete on stock_ledger for delete to authenticated using (true);
create policy stock_insert on stock_ledger for insert to authenticated with check (true);
create policy stock_update on stock_ledger for update to authenticated using (true) with check (true);
create policy stock_select on stock_ledger for select to authenticated using (true);
create policy tx_header_delete on tx_header for delete to authenticated using (true);
create policy tx_header_select on tx_header for select to authenticated using (true);
create policy tx_header_insert on tx_header for insert to authenticated with check (true);
create policy tx_header_update on tx_header for update to authenticated using (true) with check (true);
create policy tx_lines_delete on tx_lines for delete to authenticated using (true);
create policy tx_lines_update on tx_lines for update to authenticated using (true) with check (true);
create policy tx_lines_insert on tx_lines for insert to authenticated with check (true);
create policy tx_lines_select on tx_lines for select to authenticated using (true);
create policy user_profiles_insert on user_profiles for insert to public with check (true);
create policy user_profiles_select on user_profiles for select to authenticated using (true);
create policy user_profiles_update on user_profiles for update to authenticated using (true) with check (true);
