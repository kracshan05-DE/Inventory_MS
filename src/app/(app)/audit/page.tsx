'use client';

import { Fragment, useEffect, useState } from 'react';
import { useSession } from '@/components/SessionProvider';
import { Banner, Empty, Loading, PageHeader, Pagination } from '@/components/ui';
import { downloadCsv, slug } from '@/lib/csv';
import { dayEndSL, dayStartSL, firstOfMonthSL, fmtDateTime, todaySL } from '@/lib/format';
import { errText, fetchAll, supabase } from '@/lib/supabase';
import type { AuditRow } from '@/lib/types';

const PAGE_SIZE = 30;
const TABLES = ['tx_header', 'items', 'sales_reps', 'companies', 'user_profiles', 'user_company_access', 'opening_balances', 'stock_ledger', 'rep_ledger'];

interface Filters { from: string; to: string; action: string; table: string }
const defaults = (): Filters => ({ from: firstOfMonthSL(), to: todaySL(), action: '', table: '' });

/** Only the fields that changed, as "field: old -> new". */
function describeChange(oldData: unknown, newData: unknown): string | null {
  if (!oldData || !newData || typeof oldData !== 'object' || typeof newData !== 'object') return null;
  const o = oldData as Record<string, unknown>;
  const n = newData as Record<string, unknown>;
  const parts: string[] = [];
  for (const k of Object.keys(n)) {
    if (JSON.stringify(o[k]) !== JSON.stringify(n[k])) parts.push(`${k}: ${String(o[k] ?? '∅')} → ${String(n[k] ?? '∅')}`);
  }
  return parts.length ? parts.join(' · ') : null;
}

export default function AuditLogPage() {
  const { company, isAdmin } = useSession();
  const [form, setForm] = useState<Filters>(defaults);
  const [filters, setFilters] = useState<Filters>(defaults);
  const [page, setPage] = useState(1);
  const [rows, setRows] = useState<AuditRow[] | null>(null);
  const [total, setTotal] = useState(0);
  const [users, setUsers] = useState<Record<string, string>>({});
  const [open, setOpen] = useState<Set<number>>(new Set());
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!isAdmin) return;
    supabase().from('user_profiles').select('id,full_name').then(({ data }) => {
      const m: Record<string, string> = {};
      for (const u of (data ?? []) as { id: string; full_name: string }[]) m[u.id] = u.full_name;
      setUsers(m);
    });
  }, [isAdmin]);

  /** Rows for this company, plus rows not tied to any company (users), newest first. */
  function query(f: Filters, withCount: boolean) {
    let q = supabase()
      .from('audit_log')
      .select('*', withCount ? { count: 'exact' } : undefined)
      .or(`company_id.eq.${company.id},company_id.is.null`);
    if (f.from) q = q.gte('created_at', dayStartSL(f.from));
    if (f.to) q = q.lte('created_at', dayEndSL(f.to));
    if (f.action) q = q.eq('action', f.action);
    if (f.table) q = q.eq('table_name', f.table);
    return q.order('created_at', { ascending: false }).order('id', { ascending: false });
  }

  useEffect(() => {
    if (!isAdmin) return;
    let alive = true;
    setRows(null);
    (async () => {
      const from = (page - 1) * PAGE_SIZE;
      const { data, error: e, count } = await query(filters, true).range(from, from + PAGE_SIZE - 1);
      if (!alive) return;
      if (e) {
        setError(e.message);
        setRows([]);
        return;
      }
      setRows((data ?? []) as AuditRow[]);
      setTotal(count ?? 0);
      setOpen(new Set());
      setError(null);
    })();
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [company.id, filters, page, isAdmin]);

  async function exportCsv() {
    try {
      const all = await fetchAll<AuditRow>((f, t) => query(filters, false).range(f, t));
      if (all.length === 0) return;
      downloadCsv(
        `audit_log_${slug(company.name)}_${todaySL()}.csv`,
        all.map((l) => ({
          Time: fmtDateTime(l.created_at), User: (l.user_id && users[l.user_id]) || 'System', Action: l.action,
          Table: l.table_name, Record: l.record_id ?? '',
          Before: l.old_data ? JSON.stringify(l.old_data) : '', After: l.new_data ? JSON.stringify(l.new_data) : '',
        })),
      );
    } catch (e) {
      setError(errText(e));
    }
  }

  if (!isAdmin) {
    return (
      <>
        <PageHeader title="Audit Log" />
        <div className="content"><Banner kind="info">The audit log is available to admins only.</Banner></div>
      </>
    );
  }

  return (
    <>
      <PageHeader title="Audit Log" sub={company.name}>
        <button className="btn" onClick={exportCsv}>Export Excel (CSV)</button>
      </PageHeader>

      <div className="content">
        {error ? <Banner kind="error">{error}</Banner> : null}

        <div className="panel">
          <div className="panel-body">
            <form className="filters" onSubmit={(e) => { e.preventDefault(); setFilters(form); setPage(1); }}>
              <div className="field"><label htmlFor="aFrom">Date from</label><input id="aFrom" type="date" value={form.from} onChange={(e) => setForm({ ...form, from: e.target.value })} /></div>
              <div className="field"><label htmlFor="aTo">Date to</label><input id="aTo" type="date" value={form.to} onChange={(e) => setForm({ ...form, to: e.target.value })} /></div>
              <div className="field">
                <label htmlFor="aAction">Action</label>
                <select id="aAction" value={form.action} onChange={(e) => setForm({ ...form, action: e.target.value })}>
                  <option value="">All actions</option><option>INSERT</option><option>UPDATE</option><option>DELETE</option>
                </select>
              </div>
              <div className="field">
                <label htmlFor="aTable">Table</label>
                <select id="aTable" value={form.table} onChange={(e) => setForm({ ...form, table: e.target.value })}>
                  <option value="">All tables</option>
                  {TABLES.map((t) => <option key={t}>{t}</option>)}
                </select>
              </div>
              <div className="filter-actions">
                <button type="submit" className="btn btn-primary">Search</button>
                <button type="button" className="btn" onClick={() => { const d = defaults(); setForm(d); setFilters(d); setPage(1); }}>Reset</button>
              </div>
            </form>
          </div>
        </div>

        <div className="panel">
          <div className="panel-header">
            <span className="panel-title">Activity</span>
            <span className="panel-note">{total.toLocaleString()} entries · written by the database, cannot be edited</span>
          </div>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr><th>Time (SL)</th><th>User</th><th>Action</th><th>Table</th><th>Record</th><th>Change</th></tr>
              </thead>
              <tbody>
                {rows === null ? <Loading cols={6} /> : rows.length === 0 ? <Empty cols={6}>No audit entries for these filters.</Empty> : rows.map((l) => {
                  const change = describeChange(l.old_data, l.new_data);
                  const isOpen = open.has(l.id);
                  return (
                    <Fragment key={l.id}>
                      <tr>
                        <td className="muted nowrap" style={{ fontSize: 12 }}>{fmtDateTime(l.created_at)}</td>
                        <td style={{ fontWeight: 500 }}>{(l.user_id && users[l.user_id]) || 'System'}</td>
                        <td><span className={'pill ' + l.action}>{l.action}</span></td>
                        <td className="mono muted">{l.table_name}</td>
                        <td className="mono">{l.record_id ?? '—'}</td>
                        <td style={{ fontSize: 12.5 }}>
                          {change ? <div style={{ marginBottom: 2 }}>{change}</div> : null}
                          <button className="link-btn" onClick={() => setOpen((s) => { const n = new Set(s); if (n.has(l.id)) n.delete(l.id); else n.add(l.id); return n; })}>
                            {isOpen ? 'Hide data' : 'View data'}
                          </button>
                        </td>
                      </tr>
                      {isOpen ? (
                        <tr className="sub-row">
                          <td colSpan={6}>
                            <div className="sub-inner" style={{ display: 'grid', gridTemplateColumns: l.old_data && l.new_data ? '1fr 1fr' : '1fr', gap: 12 }}>
                              {l.old_data ? <div><div className="field-label">Before</div><div className="json-preview">{JSON.stringify(l.old_data, null, 2)}</div></div> : null}
                              {l.new_data ? <div><div className="field-label">After</div><div className="json-preview">{JSON.stringify(l.new_data, null, 2)}</div></div> : null}
                            </div>
                          </td>
                        </tr>
                      ) : null}
                    </Fragment>
                  );
                })}
              </tbody>
            </table>
          </div>
          <Pagination page={page} pageSize={PAGE_SIZE} total={total} onPage={setPage} />
        </div>
      </div>
    </>
  );
}
