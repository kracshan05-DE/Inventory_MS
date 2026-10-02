# InventoryIQ

Stock control for a distributor that handles several principals (Unilever, Hemas, Nestle and so on).
Goods come in (GRN), go out to sales reps (ISSUE), come back unsold (RETURN), and what is not returned is settled as sold.

- **App:** Next.js 16 (App Router, TypeScript), deployed on Vercel.
- **Database:** your existing Supabase project. Existing tables and data are kept.

## The one idea to understand

The browser is never trusted. All rules live in the database:

| Rule | Where it is enforced |
| --- | --- |
| Who can see which company | Row level security policies |
| Posting a document | `post_transaction()` |
| Undoing a document | `reverse_transaction()` |
| Document numbers | `next_doc_no()` (row-locked counter) |
| Who changed what | Audit triggers |

The app only calls those functions and reads views. A user who opens the browser console and calls the API directly gets the same answers the app gets.

## Go live

Do these in order. Steps 1 and 2 change nothing.

### 1. Preflight check (read only)

Supabase dashboard, SQL Editor: paste `supabase/00_preflight_check.sql`, run it, copy the single result cell. Two lines matter:

```
[warehouse check] items where stock_ledger <> documents: N of M
[rep check] rep/item balances where rep_ledger <> documents: N of M
```

Both `0` means the documents fully explain the balances. Anything else: run `supabase/00b_diagnose_differences.sql` (also read only) to see the cause of each one.

This was done on 2026-10-02 and found 25 differences. They are handled in step 4.

### 2. Back up

```bash
pg_dump "postgresql://postgres:<password>@db.xuhufnwgmlortnkqzgij.supabase.co:5432/postgres" \
  --schema=public --no-owner -f inventoryiq_backup.sql
```

The connection string is under Project Settings, Database.

### 3. Deploy the app

1. Push this folder to a GitHub repository.
2. Vercel: New Project, import the repository. Framework is detected as Next.js.
3. Add these two environment variables (the same values are in `.env.example`, which is a hidden file on some systems):

   | Name | Value |
   | --- | --- |
   | `NEXT_PUBLIC_SUPABASE_URL` | `https://xuhufnwgmlortnkqzgij.supabase.co` |
   | `NEXT_PUBLIC_SUPABASE_ANON_KEY` | the anon public key from Supabase, Project Settings, API |

4. Deploy. You get a `*.vercel.app` address; no domain is needed.

The app will show errors until step 4 is done. That is expected.

### 4. Run the migration, then the cutover step

SQL Editor, one after the other:

1. `supabase/01_migration.sql`. Access rules, posting functions, views. It changes no balance and no document.
2. `supabase/02_cutover_corrections.sql`. Deals with the 25 balances that did not match the documents. **It changes no balance either**: every figure stays as it is today, and each gap is written to `opening_balances` with its cause. It refuses to finish if any balance is still unexplained.

Each script is one transaction (all or nothing) and is safe to run again.

**From this moment the old HTML pages can no longer post.** They wrote straight into the tables; that door is now closed. Use the new app.

### 5. Close public sign-up

Supabase dashboard, Authentication, Sign In / Providers: turn off **Allow new users to sign up**.
The anon key is public, so with sign-up open anyone could create an account. They would see nothing (new accounts have no company access), but there is no reason to allow it.

### 6. Sign in

Use the same email and password as before. Admins see every company in the switcher at the top left.

### If something goes wrong

`supabase/99_rollback.sql` restores the old trigger and the old access rules so the HTML pages work again. Nothing posted in the new app is lost. Run `01_migration.sql` again to return.

## What changed for the people using it

- **Company is chosen after sign-in**, from a switcher. No company buttons on the login page.
- **Doc No is assigned when you post**, not before. Format is the same (`GRN-261002-001`).
- **Issue** is refused if the warehouse does not have the stock, checked at the moment of posting.
- **Return** only offers items the selected rep is holding, and not more than they hold.
- **Settle** (Rep Ledger, select a rep): after returns are posted, whatever the rep still holds is recorded as sold and the balance goes to zero. This is a `SALE` document. It does not change warehouse stock.
- **Reverse** (Transactions, admin only): creates a `REV` document that undoes the stock movement and marks the original as reversed. Nothing is ever edited or deleted.
- **Adjust** (Post Transaction, admin only): add or remove warehouse stock with a reason. For damage, loss and count corrections.
- **Editing an item's price or units per case** affects new documents only. Posted documents keep their own values.
- **Export** is CSV, which Excel opens directly. **Print / PDF** uses the browser's print dialog.

## Reconciliation

Two independent checks per item, in units:

```
warehouse expected = GRN + adjustments - issued + returned      must equal stock_ledger
with reps expected = issued - returned - settled                must equal rep_ledger
```

Reversed documents and their REV documents are left out of both; together they net to zero.

### Opening differences

The old system let some balances drift from the documents (a reversal that left stock on the rep, a return entered against an empty rep balance, an edit to units per case, stock changed by hand). At go-live those balances were kept as they were and the gap was recorded once as an **opening difference**. Reconciliation adds it to the expected side, shown in the Opening column. A difference that appears after go-live is therefore a new one.

To correct one of them later, in the SQL Editor (logged in the audit log with old and new value):

```sql
-- one balance, set to what the documents say
select public.cutover_resolve('NO 07', 'CHIT CHAT 15/=', 'KIR', 'use_documents', 'reason');

-- all rep balances left behind by reversed issues
delete from public.opening_balances where reason like 'Reversed issue:%';
select public.cutover_fix_reversed_issues();
```

Until then, note that **Settle** records whatever balance a rep shows as sold, including an overstated one.

Value figures on the dashboard are for information. They cannot be used as a balance check, because received stock is valued at the price on the GRN and stock on hand at today's price.

## Users and access

| Role | Can do |
| --- | --- |
| admin | Every company. Post, adjust, reverse, settings, audit log, manage users. |
| user | Only companies ticked for them in Settings, Users. Post GRN, issue, return, settle. Read reports. |

To add a person: Supabase dashboard, Authentication, Users, Add user. They then appear in Settings, Users with no access; an admin assigns role and companies there.

## Project layout

```
supabase/
  00_preflight_check.sql        read-only data check
  00b_diagnose_differences.sql  read-only: why a balance differs
  01_migration.sql              the database side of the app
  02_cutover_corrections.sql    records the 25 legacy gaps, changes no balance
  99_rollback.sql               back to the old pages
  tests/                        replica of the old schema, behaviour tests, cutover rehearsal
src/
  app/login                sign in
  app/(app)/dashboard      KPIs, stock levels, stock with reps
  app/(app)/post           GRN / ISSUE / RETURN / ADJUST
  app/(app)/transactions   history, filters, reverse, export
  app/(app)/reps           rep ledger, settlement
  app/(app)/reconciliation unit reconciliation
  app/(app)/audit          audit log (admin)
  app/(app)/settings       items, reps, companies, users (admin)
  components/              session, shell, shared UI
  lib/                     database client, formatting, CSV, types
```

## Run locally

```bash
cp .env.example .env.local
npm install
npm run dev          # http://localhost:3000
```

## Database tests

`supabase/tests/run.sh` rebuilds the pre-migration schema in a local throwaway Postgres (15 or newer), loads legacy-style data, runs the migration and then checks posting, reversal, settlement, validation, locking of history, access rules and the audit trail. It then rebuilds the 25 production differences and rehearses the cutover step.

```bash
PGHOST=localhost PGUSER=postgres supabase/tests/run.sh
```

Never point it at the live project: it drops and recreates its database.
