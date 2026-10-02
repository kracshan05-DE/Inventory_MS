'use client';

import Link from 'next/link';
import { useEffect, useMemo, useState } from 'react';
import { useSession } from '@/components/SessionProvider';
import { Banner, Empty, Loading, PageHeader } from '@/components/ui';
import { fmtCases, fmtInt, fmtLKR, SL_TZ } from '@/lib/format';
import { errText, fetchAll, supabase } from '@/lib/supabase';
import type { ReconRow, RepSummary } from '@/lib/types';

export default function DashboardPage() {
  const { company } = useSession();
  const [rows, setRows] = useState<ReconRow[] | null>(null);
  const [reps, setReps] = useState<RepSummary[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState('');

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const sb = supabase();
        // One row per item, totals already computed in the database.
        const [items, repRows] = await Promise.all([
          fetchAll<ReconRow>((from, to) =>
            sb.from('v_reconciliation').select('*').eq('company_id', company.id).order('item_name').range(from, to),
          ),
          fetchAll<RepSummary>((from, to) =>
            sb.from('v_rep_summary').select('*').eq('company_id', company.id).neq('held_units', 0)
              .order('held_value', { ascending: false }).range(from, to),
          ),
        ]);
        if (!alive) return;
        setRows(items);
        setReps(repRows);
      } catch (e) {
        if (alive) setError(errText(e));
      }
    })();
    return () => { alive = false; };
  }, [company.id]);

  const kpi = useMemo(() => {
    const r = rows ?? [];
    const sum = (f: (x: ReconRow) => number) => r.reduce((s, x) => s + Number(f(x)), 0);
    return {
      grn: sum((x) => x.grn_value),
      netIssued: sum((x) => x.issued_value) - sum((x) => x.returned_value),
      stock: sum((x) => x.stock_value),
      withReps: sum((x) => x.rep_value),
      gaps: r.filter((x) => x.stock_variance !== 0 || x.rep_variance !== 0).length,
    };
  }, [rows]);

  const stockRows = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (rows ?? [])
      .filter((x) => x.active || x.stock_units !== 0)
      .filter((x) => !q || x.item_name.toLowerCase().includes(q));
  }, [rows, search]);

  const low = useMemo(
    () => (rows ?? []).filter((x) => x.active && x.stock_units < 2 * x.units_per_case),
    [rows],
  );

  const today = new Date().toLocaleDateString('en-GB', {
    timeZone: SL_TZ, weekday: 'short', day: 'numeric', month: 'short', year: 'numeric',
  });

  return (
    <>
      <PageHeader title="Dashboard" sub={`${company.name} · ${today}`}>
        <Link href="/post" className="btn btn-primary">+ Post Transaction</Link>
      </PageHeader>

      <div className="content">
        {error ? <Banner kind="error">{error}</Banner> : null}

        {rows && kpi.gaps > 0 ? (
          <Banner kind="error">
            <strong>{kpi.gaps} item{kpi.gaps > 1 ? 's' : ''}</strong> do not balance against the documents.{' '}
            <Link href="/reconciliation">Open Reconciliation</Link>
          </Banner>
        ) : null}

        {low.length > 0 ? (
          <Banner kind="warn">
            <strong>Low stock ({low.length}):</strong>{' '}
            {low.slice(0, 8).map((x) => x.item_name).join(', ')}
            {low.length > 8 ? ` and ${low.length - 8} more` : ''}
          </Banner>
        ) : null}

        <div className="kpi-grid">
          <div className="kpi">
            <div className="kpi-label">Goods Received</div>
            <div className="kpi-val">{rows ? fmtLKR(kpi.grn) : '—'}</div>
            <div className="kpi-sub">All GRNs, at list price</div>
          </div>
          <div className="kpi green">
            <div className="kpi-label">Net Issued to Reps</div>
            <div className="kpi-val">{rows ? fmtLKR(kpi.netIssued) : '—'}</div>
            <div className="kpi-sub">Issued minus returned</div>
          </div>
          <div className="kpi gold">
            <div className="kpi-label">Warehouse Stock</div>
            <div className="kpi-val">{rows ? fmtLKR(kpi.stock) : '—'}</div>
            <div className="kpi-sub">At today&apos;s prices</div>
          </div>
          <div className="kpi violet">
            <div className="kpi-label">With Reps</div>
            <div className="kpi-val">{rows ? fmtLKR(kpi.withReps) : '—'}</div>
            <div className="kpi-sub">Issued, not yet returned or settled</div>
          </div>
          <div className={'kpi ' + (kpi.gaps > 0 ? 'red' : 'green')}>
            <div className="kpi-label">Unit Check</div>
            <div className={'kpi-val ' + (kpi.gaps > 0 ? 'red' : 'green')}>
              {rows ? (kpi.gaps > 0 ? `${kpi.gaps} differ` : 'Balanced') : '—'}
            </div>
            <div className="kpi-sub">Balances against documents</div>
          </div>
        </div>

        <div className="dash-grid">
          <div className="panel">
            <div className="panel-header">
              <span className="panel-title">Stock Levels</span>
              <input className="search no-print" placeholder="Search items…" value={search} onChange={(e) => setSearch(e.target.value)} />
            </div>
            <div className="table-scroll">
              <table className="table">
                <thead>
                  <tr>
                    <th>Item</th>
                    <th className="num">Cases</th>
                    <th className="num">Units</th>
                    <th className="num">Value (LKR)</th>
                  </tr>
                </thead>
                <tbody>
                  {!rows ? <Loading cols={4} /> : stockRows.length === 0 ? (
                    <Empty cols={4}>No items found.</Empty>
                  ) : stockRows.map((x) => {
                    const isLow = x.active && x.stock_units < 2 * x.units_per_case;
                    return (
                      <tr key={x.item_id}>
                        <td>
                          <span style={{ fontWeight: 500 }}>{x.item_name}</span>{' '}
                          {x.stock_units <= 0 ? <span className="pill out">OUT</span> : isLow ? <span className="pill low">LOW</span> : null}
                          {!x.active ? <span className="pill inactive" style={{ marginLeft: 4 }}>INACTIVE</span> : null}
                        </td>
                        <td className="num" style={isLow ? { color: 'var(--red)', fontWeight: 600 } : { fontWeight: 600 }}>
                          {fmtCases(x.stock_units, x.units_per_case)}
                        </td>
                        <td className="num">{fmtInt(x.stock_units)}</td>
                        <td className="num muted">{fmtLKR(x.stock_value)}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </div>

          <div className="panel">
            <div className="panel-header">
              <span className="panel-title">Stock With Reps</span>
              <span className="panel-note">{reps.length} rep{reps.length === 1 ? '' : 's'}</span>
            </div>
            {reps.length === 0 ? (
              <div className="empty">{rows ? 'No rep is holding stock.' : 'Loading…'}</div>
            ) : reps.map((r) => (
              <div key={r.rep_id} className="rep-list-item">
                <div className="rep-avatar">{r.rep_name.charAt(0).toUpperCase()}</div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontWeight: 500 }}>{r.rep_name}</div>
                  <div className="muted" style={{ fontSize: 11.5 }}>{fmtInt(r.held_units)} units held</div>
                </div>
                <div className="num" style={{ fontWeight: 600 }}>{fmtLKR(r.held_value)}</div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </>
  );
}
