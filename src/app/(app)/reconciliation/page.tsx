'use client';

import { useEffect, useMemo, useState } from 'react';
import { useSession } from '@/components/SessionProvider';
import { Banner, Empty, Loading, PageHeader } from '@/components/ui';
import { downloadCsv, slug } from '@/lib/csv';
import { fmtDateTime, fmtInt, fmtLKR, fmtSigned, todaySL } from '@/lib/format';
import { errText, fetchAll, supabase } from '@/lib/supabase';
import type { ReconRow } from '@/lib/types';

export default function ReconciliationPage() {
  const { company } = useSession();
  const [rows, setRows] = useState<ReconRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [onlyGaps, setOnlyGaps] = useState(false);
  const [loadedAt, setLoadedAt] = useState<string | null>(null);

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

  const t = useMemo(() => {
    const sum = (f: (r: ReconRow) => number) => active.reduce((s, r) => s + Number(f(r)), 0);
    return {
      grn: sum((r) => r.grn_units), adjust: sum((r) => r.adjust_units), issued: sum((r) => r.issued_units),
      returned: sum((r) => r.returned_units), sold: sum((r) => r.sold_units),
      openStock: sum((r) => r.opening_stock_units), openRep: sum((r) => r.opening_rep_units),
      expStock: sum((r) => r.expected_stock_units), stock: sum((r) => r.stock_units), stockVar: sum((r) => r.stock_variance),
      expRep: sum((r) => r.expected_rep_units), rep: sum((r) => r.rep_units), repVar: sum((r) => r.rep_variance),
      gapValue: gaps.reduce((s, r) => s + (Math.abs(r.stock_variance) + Math.abs(r.rep_variance)) * Number(r.unit_price), 0),
    };
  }, [active, gaps]);

  function exportCsv() {
    if (active.length === 0) return;
    downloadCsv(
      `reconciliation_${slug(company.name)}_${todaySL()}.csv`,
      active.map((r) => ({
        Item: r.item_name, 'GRN Units': r.grn_units, 'Adjusted Units': r.adjust_units, 'Issued Units': r.issued_units,
        'Returned Units': r.returned_units, 'Settled (Sold) Units': r.sold_units,
        'Warehouse Opening Difference': r.opening_stock_units, 'With Reps Opening Difference': r.opening_rep_units,
        'Warehouse Expected': r.expected_stock_units, 'Warehouse Actual': r.stock_units, 'Warehouse Difference': r.stock_variance,
        'With Reps Expected': r.expected_rep_units, 'With Reps Actual': r.rep_units, 'With Reps Difference': r.rep_variance,
        Status: r.stock_variance === 0 && r.rep_variance === 0 ? 'OK' : 'DIFFERENCE',
      })),
    );
  }

  const diffCell = (n: number) => (
    <td className="num" style={{ fontWeight: 600, color: n === 0 ? 'var(--green)' : 'var(--red)' }}>{fmtSigned(n)}</td>
  );

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
          <div className="kpi green"><div className="kpi-label">Received</div><div className="kpi-val">{rows ? fmtInt(t.grn + t.adjust) : '—'}</div><div className="kpi-sub">GRN {fmtInt(t.grn)}, adjustments {fmtSigned(t.adjust)}</div></div>
          <div className="kpi"><div className="kpi-label">Net Issued</div><div className="kpi-val">{rows ? fmtInt(t.issued - t.returned) : '—'}</div><div className="kpi-sub">Issued {fmtInt(t.issued)}, returned {fmtInt(t.returned)}</div></div>
          <div className="kpi gold"><div className="kpi-label">In Warehouse</div><div className="kpi-val">{rows ? fmtInt(t.stock) : '—'}</div><div className="kpi-sub">Units on hand</div></div>
          <div className="kpi violet"><div className="kpi-label">With Reps</div><div className="kpi-val">{rows ? fmtInt(t.rep) : '—'}</div><div className="kpi-sub">Settled as sold: {fmtInt(t.sold)}</div></div>
          <div className={'kpi ' + (gaps.length ? 'red' : 'green')}>
            <div className="kpi-label">Differences</div>
            <div className={'kpi-val ' + (gaps.length ? 'red' : 'green')}>{rows ? gaps.length : '—'}</div>
            <div className="kpi-sub">{gaps.length ? fmtLKR(t.gapValue) + ' at today’s prices' : 'Should be zero'}</div>
          </div>
        </div>

        <div className="panel">
          <div className="panel-header">
            <span className="panel-title">Item-wise reconciliation (units)</span>
            <label className="check-row no-print" style={{ padding: 0 }}>
              <input type="checkbox" checked={onlyGaps} onChange={(e) => setOnlyGaps(e.target.checked)} />
              Show only differences
            </label>
          </div>
          <div className="panel-body" style={{ paddingTop: 12, paddingBottom: 12, borderBottom: '1px solid var(--paper3)', fontSize: 12.5 }}>
            <div className="muted">
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
                {rows === null ? <Loading cols={15} /> : shown.length === 0 ? (
                  <Empty cols={15}>{onlyGaps ? 'No differences.' : 'No stock movements yet.'}</Empty>
                ) : shown.map((r) => {
                  const ok = r.stock_variance === 0 && r.rep_variance === 0;
                  return (
                    <tr key={r.item_id} className={ok ? undefined : 'row-bad'}>
                      <td style={{ fontWeight: 500 }}>{r.item_name}</td>
                      <td className="num">{fmtInt(r.grn_units)}</td>
                      <td className="num">{r.adjust_units === 0 ? '0' : fmtSigned(r.adjust_units)}</td>
                      <td className="num">{fmtInt(r.issued_units)}</td>
                      <td className="num">{fmtInt(r.returned_units)}</td>
                      <td className="num">{fmtInt(r.sold_units)}</td>
                      {hasOpening ? <td className="num muted">{r.opening_stock_units === 0 ? '0' : fmtSigned(r.opening_stock_units)}</td> : null}
                      <td className="num muted">{fmtInt(r.expected_stock_units)}</td>
                      <td className="num">{fmtInt(r.stock_units)}</td>
                      {diffCell(r.stock_variance)}
                      {hasOpening ? <td className="num muted">{r.opening_rep_units === 0 ? '0' : fmtSigned(r.opening_rep_units)}</td> : null}
                      <td className="num muted">{fmtInt(r.expected_rep_units)}</td>
                      <td className="num">{fmtInt(r.rep_units)}</td>
                      {diffCell(r.rep_variance)}
                      <td><span className={'pill ' + (ok ? 'ok' : 'bad')}>{ok ? 'OK' : 'DIFFERENCE'}</span></td>
                    </tr>
                  );
                })}
              </tbody>
              {rows && shown.length > 0 && !onlyGaps ? (
                <tfoot>
                  <tr>
                    <td>TOTAL</td>
                    <td className="num">{fmtInt(t.grn)}</td>
                    <td className="num">{t.adjust === 0 ? '0' : fmtSigned(t.adjust)}</td>
                    <td className="num">{fmtInt(t.issued)}</td>
                    <td className="num">{fmtInt(t.returned)}</td>
                    <td className="num">{fmtInt(t.sold)}</td>
                    {hasOpening ? <td className="num">{t.openStock === 0 ? '0' : fmtSigned(t.openStock)}</td> : null}
                    <td className="num">{fmtInt(t.expStock)}</td>
                    <td className="num">{fmtInt(t.stock)}</td>
                    <td className="num">{fmtSigned(t.stockVar)}</td>
                    {hasOpening ? <td className="num">{t.openRep === 0 ? '0' : fmtSigned(t.openRep)}</td> : null}
                    <td className="num">{fmtInt(t.expRep)}</td>
                    <td className="num">{fmtInt(t.rep)}</td>
                    <td className="num">{fmtSigned(t.repVar)}</td>
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
