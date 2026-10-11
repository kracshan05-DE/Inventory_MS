'use client';

import { useEffect, useMemo, useState } from 'react';
import { useSession } from '@/components/SessionProvider';
import { Banner, Empty, Loading, PageHeader } from '@/components/ui';
import { downloadCsv, slug } from '@/lib/csv';
import { fmtDateTime, fmtInt, fmtLKR, fmtSigned, todaySL } from '@/lib/format';
import { errText, fetchAll, supabase } from '@/lib/supabase';
import type { ReconRow } from '@/lib/types';

type Mode = 'cases' | 'units';
const MODE_KEY = 'iq_recon_mode';

/** Splits n units into whole cases and loose units, both with the sign of n. */
function split(n: number, upc: number): { c: number; u: number } {
  if (!upc || upc <= 0) return { c: 0, u: n };
  const c = Math.trunc(n / upc);
  return { c, u: n - c * upc };
}

/** "24 cs", "3 cs 12 u", "-1 cs 91 u", "+48 u". signed = show "+" on positives. */
function fmtCU(c: number, u: number, signed: boolean): string {
  if (c === 0 && u === 0) return '0';
  const sign = (n: number) => (n < 0 ? '-' : signed ? '+' : '');
  if ((c > 0 && u < 0) || (c < 0 && u > 0)) {
    // Mixed signs only happen in a TOTAL row, where items differ.
    return `${sign(c)}${fmtInt(Math.abs(c))} cs ${u < 0 ? '-' : '+'}${fmtInt(Math.abs(u))} u`;
  }
  const parts: string[] = [];
  if (c !== 0) parts.push(`${fmtInt(Math.abs(c))} cs`);
  if (u !== 0) parts.push(`${fmtInt(Math.abs(u))} u`);
  return sign(c !== 0 ? c : u) + parts.join(' ');
}

function readMode(): Mode {
  try {
    return window.localStorage.getItem(MODE_KEY) === 'units' ? 'units' : 'cases';
  } catch {
    return 'cases';
  }
}

export default function ReconciliationPage() {
  const { company } = useSession();
  const [rows, setRows] = useState<ReconRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [onlyGaps, setOnlyGaps] = useState(false);
  const [loadedAt, setLoadedAt] = useState<string | null>(null);
  const [mode, setModeState] = useState<Mode>('cases');

  useEffect(() => { setModeState(readMode()); }, []);
  function setMode(m: Mode) {
    setModeState(m);
    try { window.localStorage.setItem(MODE_KEY, m); } catch { /* not remembered, still works */ }
  }

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const sb = supabase();
        const data = await fetchAll<ReconRow>((f, t) =>
          sb.from('v_reconciliation').select('*').eq('company_id', company.id).order('item_name').range(f, t),
        );
        if (!alive) return;
        setRows(data);
        setLoadedAt(new Date().toISOString());
      } catch (e) {
        if (alive) setError(errText(e));
      }
    })();
    return () => { alive = false; };
  }, [company.id]);

  // Items with any movement or any balance.
  const active = useMemo(
    () => (rows ?? []).filter((r) =>
      r.grn_units !== 0 || r.adjust_units !== 0 || r.issued_units !== 0 || r.returned_units !== 0 ||
      r.sold_units !== 0 || r.stock_units !== 0 || r.rep_units !== 0 ||
      r.opening_stock_units !== 0 || r.opening_rep_units !== 0),
    [rows],
  );
  const gaps = useMemo(() => active.filter((r) => r.stock_variance !== 0 || r.rep_variance !== 0), [active]);
  const shown = onlyGaps ? gaps : active;
  // Opening differences exist only where a balance did not match the documents at cutover.
  const hasOpening = useMemo(() => active.some((r) => r.opening_stock_units !== 0 || r.opening_rep_units !== 0), [active]);
  const isCases = mode === 'cases';

  const t = useMemo(() => {
    const sum = (f: (r: ReconRow) => number) => active.reduce((s, r) => s + Number(f(r)), 0);
    return {
      grn: sum((r) => r.grn_units), adjust: sum((r) => r.adjust_units), issued: sum((r) => r.issued_units),
      returned: sum((r) => r.returned_units), sold: sum((r) => r.sold_units),
      stock: sum((r) => r.stock_units), rep: sum((r) => r.rep_units),
      gapValue: gaps.reduce((s, r) => s + (Math.abs(r.stock_variance) + Math.abs(r.rep_variance)) * Number(r.unit_price), 0),
    };
  }, [active, gaps]);

  /** One cell value in the chosen mode. */
  function q(n: number, upc: number, signed = false): string {
    if (!isCases) return signed && n !== 0 ? fmtSigned(n) : fmtInt(n);
    const { c, u } = split(n, upc);
    return fmtCU(c, u, signed);
  }

  /** A TOTAL cell: units are added up; in cases mode, cases and loose units are added up separately. */
  function total(f: (r: ReconRow) => number, signed = false): string {
    if (!isCases) {
      const n = active.reduce((s, r) => s + f(r), 0);
      return signed && n !== 0 ? fmtSigned(n) : fmtInt(n);
    }
    let c = 0;
    let u = 0;
    for (const r of active) {
      const p = split(f(r), r.units_per_case);
      c += p.c;
      u += p.u;
    }
    return fmtCU(c, u, signed);
  }

  function exportCsv() {
    if (active.length === 0) return;
    downloadCsv(
      `reconciliation_${slug(company.name)}_${todaySL()}.csv`,
      active.map((r) => ({
        Item: r.item_name, 'Units Per Case': r.units_per_case,
        'GRN Units': r.grn_units, 'Adjusted Units': r.adjust_units, 'Issued Units': r.issued_units,
        'Returned Units': r.returned_units, 'Settled (Sold) Units': r.sold_units,
        'Warehouse Opening Difference': r.opening_stock_units, 'With Reps Opening Difference': r.opening_rep_units,
        'Warehouse Expected': r.expected_stock_units, 'Warehouse Actual': r.stock_units, 'Warehouse Difference': r.stock_variance,
        'Warehouse Actual (Cases)': Number((r.stock_units / (r.units_per_case || 1)).toFixed(2)),
        'With Reps Expected': r.expected_rep_units, 'With Reps Actual': r.rep_units, 'With Reps Difference': r.rep_variance,
        'With Reps Actual (Cases)': Number((r.rep_units / (r.units_per_case || 1)).toFixed(2)),
        Status: r.stock_variance === 0 && r.rep_variance === 0 ? 'OK' : 'DIFFERENCE',
      })),
    );
  }

  const diffCell = (n: number, upc: number) => (
    <td className="num" style={{ fontWeight: 600, color: n === 0 ? 'var(--green)' : 'var(--red)' }}>{q(n, upc, true)}</td>
  );
  const cols = 13 + (hasOpening ? 2 : 0) + (isCases ? 1 : 0);

  return (
    <>
      <PageHeader title="Reconciliation" sub={`${company.name}${loadedAt ? ' · as of ' + fmtDateTime(loadedAt) : ''}`}>
        <button className="btn" onClick={exportCsv} disabled={active.length === 0}>Export Excel (CSV)</button>
        <button className="btn" onClick={() => window.print()}>Print / PDF</button>
      </PageHeader>

      <div className="content">
        {error ? <Banner kind="error">{error}</Banner> : null}

        {rows && gaps.length > 0 ? (
          <Banner kind="error">
            <strong>{gaps.length} item{gaps.length > 1 ? 's' : ''}</strong> do not balance. The stored balance and the
            posted documents disagree for these items. A balance can only change through a document, so this should not
            happen. Tell the person who looks after the system.
          </Banner>
        ) : null}
        {rows && gaps.length === 0 ? (
          <Banner kind="success">
            <strong>Everything balances.</strong> For every item the warehouse balance and the rep balances match the posted documents.
          </Banner>
        ) : null}

        <div className="kpi-grid">
          <div className="kpi green"><div className="kpi-label">Received (units)</div><div className="kpi-val">{rows ? fmtInt(t.grn + t.adjust) : '—'}</div><div className="kpi-sub">GRN {fmtInt(t.grn)}, adjustments {fmtSigned(t.adjust)}</div></div>
          <div className="kpi"><div className="kpi-label">Net Issued (units)</div><div className="kpi-val">{rows ? fmtInt(t.issued - t.returned) : '—'}</div><div className="kpi-sub">Issued {fmtInt(t.issued)}, returned {fmtInt(t.returned)}</div></div>
          <div className="kpi gold"><div className="kpi-label">In Warehouse (units)</div><div className="kpi-val">{rows ? fmtInt(t.stock) : '—'}</div><div className="kpi-sub">Units on hand</div></div>
          <div className="kpi violet"><div className="kpi-label">With Reps (units)</div><div className="kpi-val">{rows ? fmtInt(t.rep) : '—'}</div><div className="kpi-sub">Settled as sold: {fmtInt(t.sold)}</div></div>
          <div className={'kpi ' + (gaps.length ? 'red' : 'green')}>
            <div className="kpi-label">Differences</div>
            <div className={'kpi-val ' + (gaps.length ? 'red' : 'green')}>{rows ? gaps.length : '—'}</div>
            <div className="kpi-sub">{gaps.length ? fmtLKR(t.gapValue) + ' at today’s prices' : 'Should be zero'}</div>
          </div>
        </div>

        <div className="panel">
          <div className="panel-header">
            <span className="panel-title">Item-wise reconciliation</span>
            <div className="no-print" style={{ display: 'flex', alignItems: 'center', gap: 16, flexWrap: 'wrap' }}>
              <div style={{ display: 'flex', gap: 4 }} role="group" aria-label="Show quantities as">
                <button className={'btn btn-sm' + (isCases ? ' btn-primary' : '')} onClick={() => setMode('cases')}>Cases</button>
                <button className={'btn btn-sm' + (!isCases ? ' btn-primary' : '')} onClick={() => setMode('units')}>Units</button>
              </div>
              <label className="check-row" style={{ padding: 0 }}>
                <input type="checkbox" checked={onlyGaps} onChange={(e) => setOnlyGaps(e.target.checked)} />
                Show only differences
              </label>
            </div>
          </div>
          <div className="panel-body" style={{ paddingTop: 12, paddingBottom: 12, borderBottom: '1px solid var(--paper3)', fontSize: 12.5 }}>
            <div className="muted">
              {isCases ? <><strong>cs</strong> = full cases, <strong>u</strong> = loose units. </> : null}
              <strong>Warehouse expected</strong> = {hasOpening ? 'opening + ' : ''}GRN + adjustments − issued + returned.{' '}
              <strong>With reps expected</strong> = {hasOpening ? 'opening + ' : ''}issued − returned − settled.{' '}
              Reversed documents are left out of both.
              {hasOpening ? ' Opening is the gap between a balance and the documents on the day this app went live.' : ''}
            </div>
          </div>
          <div className="table-scroll">
            <table className="table compact">
              <thead>
                <tr>
                  <th rowSpan={2}>Item</th>
                  {isCases ? <th className="num" rowSpan={2}>Per case</th> : null}
                  <th className="num" rowSpan={2}>GRN</th>
                  <th className="num" rowSpan={2}>Adjusted</th>
                  <th className="num" rowSpan={2}>Issued</th>
                  <th className="num" rowSpan={2}>Returned</th>
                  <th className="num" rowSpan={2}>Settled</th>
                  <th colSpan={hasOpening ? 4 : 3} style={{ textAlign: 'center', borderLeft: '1px solid var(--paper3)' }}>Warehouse</th>
                  <th colSpan={hasOpening ? 4 : 3} style={{ textAlign: 'center', borderLeft: '1px solid var(--paper3)' }}>With reps</th>
                  <th rowSpan={2}>Status</th>
                </tr>
                <tr>
                  {hasOpening ? <th className="num" style={{ borderLeft: '1px solid var(--paper3)' }}>Opening</th> : null}
                  <th className="num" style={hasOpening ? undefined : { borderLeft: '1px solid var(--paper3)' }}>Expected</th>
                  <th className="num">Actual</th>
                  <th className="num">Diff</th>
                  {hasOpening ? <th className="num" style={{ borderLeft: '1px solid var(--paper3)' }}>Opening</th> : null}
                  <th className="num" style={hasOpening ? undefined : { borderLeft: '1px solid var(--paper3)' }}>Expected</th>
                  <th className="num">Actual</th>
                  <th className="num">Diff</th>
                </tr>
              </thead>
              <tbody>
                {rows === null ? <Loading cols={cols} /> : shown.length === 0 ? (
                  <Empty cols={cols}>{onlyGaps ? 'No differences.' : 'No stock movements yet.'}</Empty>
                ) : shown.map((r) => {
                  const ok = r.stock_variance === 0 && r.rep_variance === 0;
                  const upc = r.units_per_case;
                  return (
                    <tr key={r.item_id} className={ok ? undefined : 'row-bad'}>
                      <td style={{ fontWeight: 500 }}>{r.item_name}</td>
                      {isCases ? <td className="num muted">{upc}</td> : null}
                      <td className="num">{q(r.grn_units, upc)}</td>
                      <td className="num">{q(r.adjust_units, upc, true)}</td>
                      <td className="num">{q(r.issued_units, upc)}</td>
                      <td className="num">{q(r.returned_units, upc)}</td>
                      <td className="num">{q(r.sold_units, upc)}</td>
                      {hasOpening ? <td className="num muted">{q(r.opening_stock_units, upc, true)}</td> : null}
                      <td className="num muted">{q(r.expected_stock_units, upc)}</td>
                      <td className="num">{q(r.stock_units, upc)}</td>
                      {diffCell(r.stock_variance, upc)}
                      {hasOpening ? <td className="num muted">{q(r.opening_rep_units, upc, true)}</td> : null}
                      <td className="num muted">{q(r.expected_rep_units, upc)}</td>
                      <td className="num">{q(r.rep_units, upc)}</td>
                      {diffCell(r.rep_variance, upc)}
                      <td><span className={'pill ' + (ok ? 'ok' : 'bad')}>{ok ? 'OK' : 'DIFFERENCE'}</span></td>
                    </tr>
                  );
                })}
              </tbody>
              {rows && shown.length > 0 && !onlyGaps ? (
                <tfoot>
                  <tr>
                    <td>TOTAL</td>
                    {isCases ? <td /> : null}
                    <td className="num">{total((r) => r.grn_units)}</td>
                    <td className="num">{total((r) => r.adjust_units, true)}</td>
                    <td className="num">{total((r) => r.issued_units)}</td>
                    <td className="num">{total((r) => r.returned_units)}</td>
                    <td className="num">{total((r) => r.sold_units)}</td>
                    {hasOpening ? <td className="num">{total((r) => r.opening_stock_units, true)}</td> : null}
                    <td className="num">{total((r) => r.expected_stock_units)}</td>
                    <td className="num">{total((r) => r.stock_units)}</td>
                    <td className="num">{total((r) => r.stock_variance, true)}</td>
                    {hasOpening ? <td className="num">{total((r) => r.opening_rep_units, true)}</td> : null}
                    <td className="num">{total((r) => r.expected_rep_units)}</td>
                    <td className="num">{total((r) => r.rep_units)}</td>
                    <td className="num">{total((r) => r.rep_variance, true)}</td>
                    <td />
                  </tr>
                </tfoot>
              ) : null}
            </table>
          </div>
        </div>
      </div>
    </>
  );
}
