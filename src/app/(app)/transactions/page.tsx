'use client';

import { Fragment, useCallback, useEffect, useState } from 'react';
import { useSession } from '@/components/SessionProvider';
import { Banner, Empty, Loading, Modal, PageHeader, Pagination } from '@/components/ui';
import { downloadCsv, slug } from '@/lib/csv';
import { firstOfMonthSL, fmtDate, fmtDateTime, fmtInt, fmtLKR, fmtNum, todaySL } from '@/lib/format';
import { errText, fetchAll, supabase } from '@/lib/supabase';
import { TX_LABEL, type TxDocument, type TxLine, type TxSummary, type TxType } from '@/lib/types';

const PAGE_SIZE = 25;

interface Filters { from: string; to: string; type: string; repId: string; itemId: string; docNo: string; status: string }
type SortCol = 'date' | 'doc_no' | 'type' | 'doc_value';

const defaultFilters = (): Filters => ({
  from: firstOfMonthSL(), to: todaySL(), type: '', repId: '', itemId: '', docNo: '', status: '',
});

interface Option { id: number; name: string }

export default function TransactionsPage() {
  const { company, isAdmin } = useSession();

  const [form, setForm] = useState<Filters>(defaultFilters);       // what is typed
  const [filters, setFilters] = useState<Filters>(defaultFilters); // what is applied
  const [page, setPage] = useState(1);
  const [sort, setSort] = useState<{ col: SortCol; asc: boolean }>({ col: 'date', asc: false });
  const [reload, setReload] = useState(0);

  const [docs, setDocs] = useState<TxDocument[] | null>(null);
  const [total, setTotal] = useState(0);
  const [summary, setSummary] = useState<TxSummary | null>(null);
  const [repOptions, setRepOptions] = useState<Option[]>([]);
  const [itemOptions, setItemOptions] = useState<Option[]>([]);
  const [expanded, setExpanded] = useState<Record<string, TxLine[] | 'loading'>>({});
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [exporting, setExporting] = useState(false);

  const [reverseDoc, setReverseDoc] = useState<TxDocument | null>(null);
  const [reason, setReason] = useState('');
  const [reversing, setReversing] = useState(false);
  const [reverseError, setReverseError] = useState<string | null>(null);

  // Filter dropdowns.
  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const sb = supabase();
        const [reps, items] = await Promise.all([
          fetchAll<Option>((f, t) => sb.from('sales_reps').select('id,name').eq('company_id', company.id).order('name').range(f, t)),
          fetchAll<Option>((f, t) => sb.from('items').select('id,name').eq('company_id', company.id).order('name').range(f, t)),
        ]);
        if (!alive) return;
        setRepOptions(reps);
        setItemOptions(items);
      } catch (e) {
        if (alive) setError(errText(e));
      }
    })();
    return () => { alive = false; };
  }, [company.id]);

  // One page of documents + totals for ALL matching documents.
  // Filtering, sorting and paging all happen in the database.
  useEffect(() => {
    let alive = true;
    setDocs(null);
    (async () => {
      try {
        const sb = supabase();
        let q = sb.from('v_tx_documents').select('*', { count: 'exact' }).eq('company_id', company.id);
        if (filters.from) q = q.gte('date', filters.from);
        if (filters.to) q = q.lte('date', filters.to);
        if (filters.type) q = q.eq('type', filters.type);
        if (filters.status) q = q.eq('status', filters.status);
        if (filters.repId) q = q.eq('rep_id', Number(filters.repId));
        if (filters.itemId) q = q.contains('item_ids', [Number(filters.itemId)]);
        if (filters.docNo) q = q.ilike('doc_no', `%${filters.docNo.replace(/[%_\\]/g, '\\$&')}%`);
        q = q.order(sort.col, { ascending: sort.asc });
        if (sort.col !== 'doc_no') q = q.order('created_at', { ascending: sort.asc }).order('doc_no', { ascending: true });

        const from = (page - 1) * PAGE_SIZE;
        const [list, sum] = await Promise.all([
          q.range(from, from + PAGE_SIZE - 1),
          sb.rpc('tx_summary', {
            p_company_id: company.id,
            p_from: filters.from || null,
            p_to: filters.to || null,
            p_type: filters.type || null,
            p_rep_id: filters.repId ? Number(filters.repId) : null,
            p_item_id: filters.itemId ? Number(filters.itemId) : null,
            p_doc_no: filters.docNo || null,
            p_status: filters.status || null,
          }),
        ]);
        if (list.error) throw new Error(list.error.message);
        if (sum.error) throw new Error(sum.error.message);
        if (!alive) return;
        setDocs((list.data ?? []) as TxDocument[]);
        setTotal(list.count ?? 0);
        setSummary(((sum.data as TxSummary[] | null) ?? [])[0] ?? null);
        setExpanded({});
        setError(null);
      } catch (e) {
        if (alive) {
          setDocs([]);
          setError(errText(e));
        }
      }
    })();
    return () => { alive = false; };
  }, [company.id, filters, page, sort, reload]);

  function apply() {
    setFilters({ ...form, docNo: form.docNo.trim() });
    setPage(1);
  }
  function reset() {
    const d = defaultFilters();
    setForm(d);
    setFilters(d);
    setPage(1);
  }
  function sortBy(col: SortCol) {
    setSort((s) => (s.col === col ? { col, asc: !s.asc } : { col, asc: false }));
    setPage(1);
  }

  const toggle = useCallback(async (docNo: string) => {
    if (expanded[docNo]) {
      setExpanded((x) => {
        const { [docNo]: _removed, ...rest } = x;
        return rest;
      });
      return;
    }
    setExpanded((x) => ({ ...x, [docNo]: 'loading' }));
    const { data, error: e } = await supabase().from('v_tx_lines').select('*').eq('doc_no', docNo).order('item_name');
    if (e) {
      setError(e.message);
      setExpanded((x) => {
        const { [docNo]: _removed, ...rest } = x;
        return rest;
      });
      return;
    }
    setExpanded((x) => ({ ...x, [docNo]: (data ?? []) as TxLine[] }));
  }, [expanded]);

  async function exportCsv() {
    setExporting(true);
    try {
      const sb = supabase();
      const rows = await fetchAll<TxLine>((f, t) => {
        let q = sb.from('v_tx_lines').select('*').eq('company_id', company.id);
        if (filters.from) q = q.gte('date', filters.from);
        if (filters.to) q = q.lte('date', filters.to);
        if (filters.type) q = q.eq('type', filters.type);
        if (filters.status) q = q.eq('status', filters.status);
        if (filters.repId) q = q.eq('rep_id', Number(filters.repId));
        if (filters.itemId) q = q.eq('item_id', Number(filters.itemId));
        if (filters.docNo) q = q.ilike('doc_no', `%${filters.docNo.replace(/[%_\\]/g, '\\$&')}%`);
        return q.order('date', { ascending: false }).order('doc_no').order('line_id').range(f, t);
      });
      if (rows.length === 0) {
        setNotice('Nothing to export for these filters.');
        return;
      }
      downloadCsv(
        `transactions_${slug(company.name)}_${todaySL()}.csv`,
        rows.map((l) => ({
          'Doc No': l.doc_no, Date: l.date, Type: l.type, Status: l.status, Rep: l.rep_name ?? '',
          Item: l.item_name, Cases: l.qty_cases, Units: l.qty_units, 'Free Units': l.free_units,
          'Units Per Case': l.units_per_case, 'Total Units': l.total_units, 'Unit Price': Number(l.unit_price),
          'Disc %': Number(l.disc_pct), 'Disc Amt': Number(l.disc_amt), 'Line Value': Number(l.line_value),
          Remarks: l.remarks ?? '', 'Posted By': l.posted_by_name ?? '', 'Posted At': fmtDateTime(l.created_at),
        })),
      );
    } catch (e) {
      setError(errText(e));
    } finally {
      setExporting(false);
    }
  }

  async function confirmReverse() {
    if (!reverseDoc) return;
    if (!reason.trim()) {
      setReverseError('Give a reason for the reversal.');
      return;
    }
    setReversing(true);
    setReverseError(null);
    const { data, error: e } = await supabase().rpc('reverse_transaction', { p_doc_no: reverseDoc.doc_no, p_reason: reason.trim() });
    setReversing(false);
    if (e) {
      setReverseError(e.message);
      return;
    }
    setNotice(`${reverseDoc.doc_no} reversed by ${String(data)}. Stock balances are restored.`);
    setReverseDoc(null);
    setReason('');
    setReload((n) => n + 1);
  }

  const arrow = (col: SortCol) => (sort.col === col ? (sort.asc ? ' ▲' : ' ▼') : '');
  const net = summary ? Number(summary.issued_value) - Number(summary.returned_value) : 0;
  const cols = 10;

  return (
    <>
      <PageHeader title="Transaction History" sub={company.name}>
        <button className="btn" onClick={exportCsv} disabled={exporting}>{exporting ? 'Exporting…' : 'Export Excel (CSV)'}</button>
        <button className="btn" onClick={() => window.print()}>Print / PDF</button>
      </PageHeader>

      <div className="content">
        {error ? <Banner kind="error">{error}</Banner> : null}
        {notice ? <Banner kind="success">{notice}</Banner> : null}

        <div className="panel no-print">
          <div className="panel-body">
            <form className="filters" onSubmit={(e) => { e.preventDefault(); apply(); }}>
              <div className="field">
                <label htmlFor="fFrom">Date from</label>
                <input id="fFrom" type="date" value={form.from} onChange={(e) => setForm({ ...form, from: e.target.value })} />
              </div>
              <div className="field">
                <label htmlFor="fTo">Date to</label>
                <input id="fTo" type="date" value={form.to} onChange={(e) => setForm({ ...form, to: e.target.value })} />
              </div>
              <div className="field">
                <label htmlFor="fType">Type</label>
                <select id="fType" value={form.type} onChange={(e) => setForm({ ...form, type: e.target.value })}>
                  <option value="">All types</option>
                  {(Object.keys(TX_LABEL) as TxType[]).map((t) => <option key={t} value={t}>{TX_LABEL[t]}</option>)}
                </select>
              </div>
              <div className="field">
                <label htmlFor="fStatus">Status</label>
                <select id="fStatus" value={form.status} onChange={(e) => setForm({ ...form, status: e.target.value })}>
                  <option value="">All</option>
                  <option value="active">Active only</option>
                  <option value="reversed">Reversed only</option>
                </select>
              </div>
              <div className="field">
                <label htmlFor="fRep">Sales rep</label>
                <select id="fRep" value={form.repId} onChange={(e) => setForm({ ...form, repId: e.target.value })}>
                  <option value="">All reps</option>
                  {repOptions.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
                </select>
              </div>
              <div className="field">
                <label htmlFor="fItem">Item</label>
                <select id="fItem" value={form.itemId} onChange={(e) => setForm({ ...form, itemId: e.target.value })}>
                  <option value="">All items</option>
                  {itemOptions.map((i) => <option key={i.id} value={i.id}>{i.name}</option>)}
                </select>
              </div>
              <div className="field">
                <label htmlFor="fDoc">Doc no</label>
                <input id="fDoc" type="text" placeholder="e.g. GRN-2610" value={form.docNo} onChange={(e) => setForm({ ...form, docNo: e.target.value })} />
              </div>
              <div className="filter-actions">
                <button type="submit" className="btn btn-primary">Search</button>
                <button type="button" className="btn" onClick={reset}>Reset</button>
              </div>
            </form>
          </div>
        </div>

        <div className="kpi-grid">
          <div className="kpi"><div className="kpi-label">Documents</div><div className="kpi-val">{summary ? fmtInt(summary.doc_count) : '—'}</div><div className="kpi-sub">Matching the filters</div></div>
          <div className="kpi green"><div className="kpi-label">GRN Value</div><div className="kpi-val">{summary ? fmtLKR(summary.grn_value) : '—'}</div><div className="kpi-sub">After discounts</div></div>
          <div className="kpi"><div className="kpi-label">Issue Value</div><div className="kpi-val">{summary ? fmtLKR(summary.issued_value) : '—'}</div><div className="kpi-sub">To reps</div></div>
          <div className="kpi gold"><div className="kpi-label">Return Value</div><div className="kpi-val">{summary ? fmtLKR(summary.returned_value) : '—'}</div><div className="kpi-sub">From reps</div></div>
          <div className="kpi violet"><div className="kpi-label">Net Issued</div><div className="kpi-val">{summary ? fmtLKR(net) : '—'}</div><div className="kpi-sub">Reversed documents excluded</div></div>
        </div>

        <div className="panel">
          <div className="panel-header">
            <span className="panel-title">Transactions</span>
            <span className="panel-note">{fmtInt(total)} results</span>
          </div>
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th style={{ width: 32 }} />
                  <th className="sortable" onClick={() => sortBy('doc_no')}>Doc No{arrow('doc_no')}</th>
                  <th className="sortable" onClick={() => sortBy('date')}>Date{arrow('date')}</th>
                  <th className="sortable" onClick={() => sortBy('type')}>Type{arrow('type')}</th>
                  <th>Rep</th>
                  <th className="num">Items</th>
                  <th className="num sortable" onClick={() => sortBy('doc_value')}>Value{arrow('doc_value')}</th>
                  <th>Posted by</th>
                  <th>Posted at</th>
                  <th className="no-print" />
                </tr>
              </thead>
              <tbody>
                {docs === null ? <Loading cols={cols} /> : docs.length === 0 ? (
                  <Empty cols={cols}>No transactions found for these filters.</Empty>
                ) : docs.map((d) => {
                  const ex = expanded[d.doc_no];
                  const canReverse = isAdmin && d.status === 'active' && d.type !== 'REV';
                  return (
                    <Fragment key={d.doc_no}>
                      <tr className={d.status === 'reversed' ? 'row-muted' : undefined}>
                        <td>
                          <button className="icon-btn no-print" style={{ fontSize: 12 }} aria-label="Show lines" onClick={() => toggle(d.doc_no)}>
                            {ex ? '▼' : '▶'}
                          </button>
                        </td>
                        <td className="mono nowrap">{d.doc_no}</td>
                        <td className="nowrap">{fmtDate(d.date)}</td>
                        <td className="nowrap">
                          <span className={'pill ' + d.type}>{TX_LABEL[d.type] ?? d.type}</span>{' '}
                          {d.status === 'reversed' ? <span className="pill reversed">REVERSED</span> : null}
                        </td>
                        <td>{d.rep_name ?? '—'}</td>
                        <td className="num muted">{d.line_count}</td>
                        <td className="num" style={{ fontWeight: 600 }}>{fmtLKR(d.doc_value)}</td>
                        <td className="muted" style={{ fontSize: 12 }}>{d.posted_by_name ?? '—'}</td>
                        <td className="muted nowrap" style={{ fontSize: 12 }}>{fmtDateTime(d.created_at)}</td>
                        <td className="right no-print">
                          {canReverse ? (
                            <button className="btn btn-sm btn-danger" onClick={() => { setReverseDoc(d); setReason(''); setReverseError(null); }}>Reverse</button>
                          ) : null}
                        </td>
                      </tr>
                      {ex ? (
                        <tr className="sub-row">
                          <td colSpan={cols}>
                            <div className="sub-inner">
                              {d.remarks ? <div className="muted" style={{ fontSize: 12, marginBottom: 6 }}>Remarks: {d.remarks}</div> : null}
                              {d.reversed_by ? <div className="muted" style={{ fontSize: 12, marginBottom: 6 }}>Reversed by <span className="mono">{d.reversed_by}</span></div> : null}
                              {d.reversal_of ? <div className="muted" style={{ fontSize: 12, marginBottom: 6 }}>Reversal of <span className="mono">{d.reversal_of}</span></div> : null}
                              {ex === 'loading' ? <div className="muted">Loading…</div> : ex.length === 0 ? (
                                <div className="muted">This document has no lines.</div>
                              ) : (
                                <table className="table">
                                  <thead>
                                    <tr>
                                      <th>Item</th><th className="num">Cases</th><th className="num">Units</th><th className="num">Free</th>
                                      <th className="num">Per case</th><th className="num">Total units</th><th className="num">Unit price</th>
                                      <th className="num">Disc %</th><th className="num">Disc amt</th><th className="num">Value</th>
                                    </tr>
                                  </thead>
                                  <tbody>
                                    {ex.map((l) => (
                                      <tr key={l.line_id}>
                                        <td>{l.item_name}</td>
                                        <td className="num">{l.qty_cases}</td>
                                        <td className="num">{l.qty_units}</td>
                                        <td className="num">{l.free_units}</td>
                                        <td className="num">{l.units_per_case}</td>
                                        <td className="num">{fmtInt(l.total_units)}</td>
                                        <td className="num">{fmtNum(l.unit_price)}</td>
                                        <td className="num">{Number(l.disc_pct) > 0 ? Number(l.disc_pct) + '%' : '—'}</td>
                                        <td className="num">{Number(l.disc_amt) > 0 ? fmtNum(l.disc_amt) : '—'}</td>
                                        <td className="num" style={{ fontWeight: 600 }}>{fmtLKR(l.line_value)}</td>
                                      </tr>
                                    ))}
                                  </tbody>
                                </table>
                              )}
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

      {reverseDoc ? (
        <Modal
          title="Reverse transaction"
          onClose={() => (reversing ? undefined : setReverseDoc(null))}
          footer={
            <>
              <button className="btn" disabled={reversing} onClick={() => setReverseDoc(null)}>Cancel</button>
              <button className="btn btn-danger-solid" disabled={reversing} onClick={confirmReverse}>
                {reversing ? 'Reversing…' : 'Reverse'}
              </button>
            </>
          }
        >
          {reverseError ? <Banner kind="error">{reverseError}</Banner> : null}
          <p style={{ marginBottom: 14, lineHeight: 1.6 }}>
            <span className="mono">{reverseDoc.doc_no}</span> ({TX_LABEL[reverseDoc.type]}, {fmtLKR(reverseDoc.doc_value)}) will be
            marked as reversed and a REV document will undo its stock movement. Both stay in the history. This cannot be undone;
            post the document again if you reverse it by mistake.
          </p>
          <div className="field">
            <label htmlFor="reason">Reason</label>
            <textarea id="reason" rows={2} autoFocus value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. wrong rep selected" />
          </div>
        </Modal>
      ) : null}
    </>
  );
}
