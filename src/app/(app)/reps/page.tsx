'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import { useSession } from '@/components/SessionProvider';
import { Banner, Empty, Loading, Modal, PageHeader, Pagination } from '@/components/ui';
import { downloadCsv, slug } from '@/lib/csv';
import { fmtCases, fmtDate, fmtInt, fmtLKR, fmtNum, todaySL } from '@/lib/format';
import { errText, fetchAll, supabase } from '@/lib/supabase';
import { TX_LABEL, type PostLine, type RepHolding, type RepSummary, type TxLine } from '@/lib/types';

const HISTORY_PAGE = 50;

export default function RepLedgerPage() {
  const { company } = useSession();

  const [reps, setReps] = useState<RepSummary[] | null>(null);
  const [selected, setSelected] = useState<number | null>(null);
  const [tab, setTab] = useState<'stock' | 'history'>('stock');
  const [holdings, setHoldings] = useState<RepHolding[] | null>(null);
  const [history, setHistory] = useState<TxLine[] | null>(null);
  const [historyTotal, setHistoryTotal] = useState(0);
  const [historyPage, setHistoryPage] = useState(1);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const [settleOpen, setSettleOpen] = useState(false);
  const [settleDate, setSettleDate] = useState(todaySL());
  const [settleRemarks, setSettleRemarks] = useState('');
  const [settling, setSettling] = useState(false);
  const [settleError, setSettleError] = useState<string | null>(null);

  const loadReps = useCallback(async () => {
    const sb = supabase();
    const rows = await fetchAll<RepSummary>((f, t) =>
      sb.from('v_rep_summary').select('*').eq('company_id', company.id).order('rep_name').range(f, t),
    );
    setReps(rows);
  }, [company.id]);

  const loadHoldings = useCallback(async (repId: number) => {
    const sb = supabase();
    const rows = await fetchAll<RepHolding>((f, t) =>
      sb.from('v_rep_holdings').select('*').eq('company_id', company.id).eq('rep_id', repId).order('item_name').range(f, t),
    );
    setHoldings(rows);
  }, [company.id]);

  useEffect(() => {
    loadReps().catch((e) => setError(errText(e)));
  }, [loadReps]);

  useEffect(() => {
    if (selected === null) return;
    setHoldings(null);
    loadHoldings(selected).catch((e) => setError(errText(e)));
  }, [selected, loadHoldings]);

  useEffect(() => {
    if (selected === null) return;
    let alive = true;
    setHistory(null);
    (async () => {
      const from = (historyPage - 1) * HISTORY_PAGE;
      const { data, error: e, count } = await supabase()
        .from('v_tx_lines').select('*', { count: 'exact' })
        .eq('company_id', company.id).eq('rep_id', selected).in('type', ['ISS', 'RET', 'SALE'])
        .order('date', { ascending: false }).order('created_at', { ascending: false }).order('line_id')
        .range(from, from + HISTORY_PAGE - 1);
      if (!alive) return;
      if (e) {
        setError(e.message);
        setHistory([]);
        return;
      }
      setHistory((data ?? []) as TxLine[]);
      setHistoryTotal(count ?? 0);
    })();
    return () => { alive = false; };
  }, [selected, historyPage, company.id]);

  // Reps worth showing: active, or with any history or balance.
  const shown = useMemo(
    () => (reps ?? []).filter((r) => r.active || r.issued_units > 0 || r.held_units !== 0),
    [reps],
  );
  const totals = useMemo(() => {
    const sum = (f: (r: RepSummary) => number) => shown.reduce((s, r) => s + Number(f(r)), 0);
    return {
      holding: shown.filter((r) => r.held_units > 0).length,
      issued: sum((r) => r.issued_value),
      returned: sum((r) => r.returned_value),
      sold: sum((r) => r.sold_value),
      held: sum((r) => r.held_value),
    };
  }, [shown]);

  const rep = shown.find((r) => r.rep_id === selected) ?? null;
  const settleLines = (holdings ?? []).filter((h) => h.qty_units_held > 0);
  const settleValue = settleLines.reduce((s, h) => s + Number(h.held_value), 0);

  function select(repId: number) {
    setSelected(repId);
    setTab('stock');
    setHistoryPage(1);
    setNotice(null);
  }

  async function settle() {
    if (!rep) return;
    if (!settleDate || settleDate > todaySL()) {
      setSettleError('Choose a date that is not in the future.');
      return;
    }
    setSettling(true);
    setSettleError(null);
    // A settlement is a SALE document: everything the rep still holds is
    // confirmed sold. It lowers the rep balance and does not touch the warehouse.
    const lines: PostLine[] = settleLines.map((h) => ({
      item_id: h.item_id, qty_cases: 0, qty_units: h.qty_units_held, free_units: 0, disc_pct: 0, disc_amt: 0,
    }));
    const { data, error: e } = await supabase().rpc('post_transaction', {
      p_company_id: company.id,
      p_type: 'SALE',
      p_date: settleDate,
      p_rep_id: rep.rep_id,
      p_remarks: settleRemarks.trim() || 'Settlement',
      p_lines: lines,
    });
    setSettling(false);
    if (e) {
      setSettleError(e.message);
      return;
    }
    setSettleOpen(false);
    setSettleRemarks('');
    setNotice(`${rep.rep_name} settled: ${String(data)} (${fmtLKR(settleValue)}).`);
    setHistoryPage(1);
    try {
      await Promise.all([loadReps(), loadHoldings(rep.rep_id)]);
    } catch (err) {
      setError(errText(err));
    }
  }

  async function exportCsv() {
    try {
      const sb = supabase();
      const rows = await fetchAll<RepHolding>((f, t) =>
        sb.from('v_rep_holdings').select('*').eq('company_id', company.id).order('rep_name').order('item_name').range(f, t),
      );
      if (rows.length === 0) {
        setNotice('No rep is holding stock, nothing to export.');
        return;
      }
      downloadCsv(
        `rep_ledger_${slug(company.name)}_${todaySL()}.csv`,
        rows.map((h) => ({
          Rep: h.rep_name, Item: h.item_name, 'Units Held': h.qty_units_held,
          Cases: Number((h.qty_units_held / (h.units_per_case || 1)).toFixed(2)),
          'Unit Price': Number(h.unit_price), 'Value (LKR)': Number(h.held_value),
        })),
      );
    } catch (e) {
      setError(errText(e));
    }
  }

  return (
    <>
      <PageHeader title="Rep Ledger" sub={company.name}>
        <button className="btn" onClick={exportCsv}>Export Excel (CSV)</button>
      </PageHeader>

      <div className="content">
        {error ? <Banner kind="error">{error}</Banner> : null}
        {notice ? <Banner kind="success">{notice}</Banner> : null}

        <div className="kpi-grid">
          <div className="kpi"><div className="kpi-label">Reps Holding Stock</div><div className="kpi-val">{reps ? totals.holding : '—'}</div><div className="kpi-sub">of {shown.length} reps</div></div>
          <div className="kpi gold"><div className="kpi-label">Total Issued</div><div className="kpi-val">{reps ? fmtLKR(totals.issued) : '—'}</div><div className="kpi-sub">All time</div></div>
          <div className="kpi green"><div className="kpi-label">Total Returned</div><div className="kpi-val">{reps ? fmtLKR(totals.returned) : '—'}</div><div className="kpi-sub">Back in the warehouse</div></div>
          <div className="kpi violet"><div className="kpi-label">Settled as Sold</div><div className="kpi-val">{reps ? fmtLKR(totals.sold) : '—'}</div><div className="kpi-sub">Confirmed by settlement</div></div>
          <div className="kpi red"><div className="kpi-label">Still With Reps</div><div className="kpi-val">{reps ? fmtLKR(totals.held) : '—'}</div><div className="kpi-sub">At today&apos;s prices</div></div>
        </div>

        {reps === null ? <div className="empty">Loading…</div> : shown.length === 0 ? (
          <div className="empty">No sales reps for this company yet. An admin can add them in Settings.</div>
        ) : (
          <div className="rep-grid">
            {shown.map((r) => (
              <button key={r.rep_id} type="button" className={'rep-card' + (selected === r.rep_id ? ' selected' : '')} onClick={() => select(r.rep_id)}>
                <div className="rep-card-header">
                  <div className="rep-avatar">{r.rep_name.charAt(0).toUpperCase()}</div>
                  <div>
                    <div className="rep-card-name">{r.rep_name}{!r.active ? <span className="pill inactive" style={{ marginLeft: 6 }}>INACTIVE</span> : null}</div>
                    <div className="rep-card-sub">{r.item_count} item type{r.item_count === 1 ? '' : 's'} on hand</div>
                  </div>
                </div>
                <div className="rep-card-body">
                  <div><div className="rep-stat-val">{fmtNum(r.issued_value)}</div><div className="rep-stat-label">Issued (LKR)</div></div>
                  <div><div className="rep-stat-val">{fmtNum(r.returned_value)}</div><div className="rep-stat-label">Returned</div></div>
                  <div><div className={'rep-stat-val' + (r.held_units > 0 ? ' red' : '')}>{fmtNum(r.held_value)}</div><div className="rep-stat-label">Holding</div></div>
                </div>
              </button>
            ))}
          </div>
        )}

        {rep ? (
          <div className="panel">
            <div className="panel-header">
              <span className="panel-title" style={{ fontSize: 15 }}>{rep.rep_name}</span>
              <div style={{ display: 'flex', gap: 8 }}>
                {settleLines.length > 0 ? (
                  <button className="btn btn-primary btn-sm" disabled={!company.active}
                    onClick={() => { setSettleDate(todaySL()); setSettleError(null); setSettleOpen(true); }}>
                    Settle: mark held stock as sold
                  </button>
                ) : null}
                <button className="btn btn-sm" onClick={() => setSelected(null)}>Close</button>
              </div>
            </div>
            <div className="line-tabs">
              <button className={'line-tab' + (tab === 'stock' ? ' active' : '')} onClick={() => setTab('stock')}>Stock held now</button>
              <button className={'line-tab' + (tab === 'history' ? ' active' : '')} onClick={() => setTab('history')}>Transaction history</button>
            </div>

            {tab === 'stock' ? (
              <div className="table-wrap">
                <table className="table">
                  <thead>
                    <tr><th>Item</th><th className="num">Units held</th><th className="num">Cases</th><th className="num">Value (LKR)</th></tr>
                  </thead>
                  <tbody>
                    {holdings === null ? <Loading cols={4} /> : holdings.length === 0 ? (
                      <Empty cols={4}>No stock held. Everything issued has been returned or settled.</Empty>
                    ) : holdings.map((h) => (
                      <tr key={h.item_id}>
                        <td style={{ fontWeight: 500 }}>{h.item_name}</td>
                        <td className="num">{fmtInt(h.qty_units_held)}</td>
                        <td className="num">{fmtCases(h.qty_units_held, h.units_per_case)}</td>
                        <td className="num">{fmtLKR(h.held_value)}</td>
                      </tr>
                    ))}
                  </tbody>
                  {holdings && holdings.length > 0 ? (
                    <tfoot>
                      <tr>
                        <td>Total</td>
                        <td className="num">{fmtInt(holdings.reduce((s, h) => s + h.qty_units_held, 0))}</td>
                        <td />
                        <td className="num">{fmtLKR(holdings.reduce((s, h) => s + Number(h.held_value), 0))}</td>
                      </tr>
                    </tfoot>
                  ) : null}
                </table>
              </div>
            ) : (
              <>
                <div className="table-wrap">
                  <table className="table">
                    <thead>
                      <tr>
                        <th>Doc No</th><th>Date</th><th>Type</th><th>Item</th>
                        <th className="num">Cases</th><th className="num">Units</th><th className="num">Total units</th><th className="num">Value</th>
                      </tr>
                    </thead>
                    <tbody>
                      {history === null ? <Loading cols={8} /> : history.length === 0 ? (
                        <Empty cols={8}>No transactions for this rep.</Empty>
                      ) : history.map((l) => (
                        <tr key={l.line_id} className={l.status === 'reversed' ? 'row-muted' : undefined}>
                          <td className="mono nowrap">{l.doc_no}</td>
                          <td className="nowrap">{fmtDate(l.date)}</td>
                          <td className="nowrap">
                            <span className={'pill ' + l.type}>{TX_LABEL[l.type]}</span>{' '}
                            {l.status === 'reversed' ? <span className="pill reversed">REVERSED</span> : null}
                          </td>
                          <td>{l.item_name}</td>
                          <td className="num">{l.qty_cases}</td>
                          <td className="num">{l.qty_units}</td>
                          <td className="num">{fmtInt(l.total_units)}</td>
                          <td className="num" style={{ fontWeight: 600 }}>{fmtLKR(l.gross_value)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
                <Pagination page={historyPage} pageSize={HISTORY_PAGE} total={historyTotal} onPage={setHistoryPage} />
              </>
            )}
          </div>
        ) : null}
      </div>

      {settleOpen && rep ? (
        <Modal
          title={`Settle ${rep.rep_name}`}
          wide
          onClose={() => (settling ? undefined : setSettleOpen(false))}
          footer={
            <>
              <button className="btn" disabled={settling} onClick={() => setSettleOpen(false)}>Cancel</button>
              <button className="btn btn-primary" disabled={settling} onClick={settle}>
                {settling ? 'Settling…' : `Confirm sold: ${fmtLKR(settleValue)}`}
              </button>
            </>
          }
        >
          {settleError ? <Banner kind="error">{settleError}</Banner> : null}
          <p style={{ marginBottom: 14, lineHeight: 1.6 }}>
            Post any <strong>returns first</strong>. Whatever is still listed below is then recorded as sold
            and {rep.rep_name}&apos;s balance goes to zero. Warehouse stock does not change.
          </p>
          <table className="table" style={{ marginBottom: 16 }}>
            <thead><tr><th>Item</th><th className="num">Units</th><th className="num">Value (LKR)</th></tr></thead>
            <tbody>
              {settleLines.map((h) => (
                <tr key={h.item_id}><td>{h.item_name}</td><td className="num">{fmtInt(h.qty_units_held)}</td><td className="num">{fmtLKR(h.held_value)}</td></tr>
              ))}
            </tbody>
          </table>
          <div className="form-grid" style={{ gridTemplateColumns: '180px 1fr' }}>
            <div className="field">
              <label htmlFor="sDate">Settlement date</label>
              <input id="sDate" type="date" max={todaySL()} value={settleDate} onChange={(e) => setSettleDate(e.target.value)} />
            </div>
            <div className="field">
              <label htmlFor="sRemarks">Remarks</label>
              <input id="sRemarks" type="text" value={settleRemarks} onChange={(e) => setSettleRemarks(e.target.value)} placeholder="Optional" />
            </div>
          </div>
        </Modal>
      ) : null}
    </>
  );
}
