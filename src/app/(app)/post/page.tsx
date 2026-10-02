'use client';

import Link from 'next/link';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useSession } from '@/components/SessionProvider';
import { Banner, Modal, PageHeader } from '@/components/ui';
import { fmtCases, fmtInt, fmtLKR, fmtNum, parseAmount, parseQty, todaySL } from '@/lib/format';
import { errText, fetchAll, supabase } from '@/lib/supabase';
import type { PostLine, RepHolding, SalesRep, StockRow } from '@/lib/types';

type PostType = 'GRN' | 'ISS' | 'RET' | 'AJUST';

interface Line {
  key: number;
  itemId: number | null;
  cases: string;
  units: string;
  free: string;
  discPct: string;
  discAmt: string;
}

/** An item as offered in the picker for the current transaction type. */
interface Pickable {
  itemId: number;
  name: string;
  upc: number;
  price: number;
  /** Warehouse stock, or units held by the rep for a RETURN. */
  available: number;
  /** True when "available" is a hard limit for this transaction. */
  limited: boolean;
}

const TYPES: { type: PostType; label: string; desc: string; adminOnly?: boolean }[] = [
  { type: 'GRN', label: 'GRN', desc: 'Goods received' },
  { type: 'ISS', label: 'ISSUE', desc: 'Issue to rep' },
  { type: 'RET', label: 'RETURN', desc: 'Return from rep' },
  { type: 'AJUST', label: 'ADJUST', desc: 'Stock correction', adminOnly: true },
];

export default function PostTransactionPage() {
  const { company, isAdmin } = useSession();
  const nextKey = useRef(1);
  const newLine = useCallback(
    (): Line => ({ key: nextKey.current++, itemId: null, cases: '', units: '', free: '', discPct: '', discAmt: '' }),
    [],
  );

  const [type, setType] = useState<PostType>('GRN');
  const [date, setDate] = useState(todaySL());
  const [repId, setRepId] = useState('');
  const [remarks, setRemarks] = useState('');
  const [direction, setDirection] = useState<'in' | 'out'>('out');
  const [lines, setLines] = useState<Line[]>(() => [newLine(), newLine(), newLine()]);

  const [stock, setStock] = useState<StockRow[] | null>(null);
  const [reps, setReps] = useState<SalesRep[]>([]);
  const [holdings, setHoldings] = useState<RepHolding[]>([]);

  const [pickerFor, setPickerFor] = useState<number | null>(null);
  const [pickerSearch, setPickerSearch] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [posted, setPosted] = useState<{ docNo: string; summary: string } | null>(null);

  const loadStock = useCallback(async () => {
    const sb = supabase();
    const rows = await fetchAll<StockRow>((from, to) =>
      sb.from('v_stock').select('*').eq('company_id', company.id).order('item_name').range(from, to),
    );
    setStock(rows);
  }, [company.id]);

  const loadHoldings = useCallback(async (rep: string) => {
    if (!rep) {
      setHoldings([]);
      return;
    }
    const sb = supabase();
    const rows = await fetchAll<RepHolding>((from, to) =>
      sb.from('v_rep_holdings').select('*').eq('company_id', company.id).eq('rep_id', Number(rep))
        .gt('qty_units_held', 0).order('item_name').range(from, to),
    );
    setHoldings(rows);
  }, [company.id]);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        await loadStock();
        const { data, error: e } = await supabase()
          .from('sales_reps').select('id,company_id,name,active').eq('company_id', company.id).order('name');
        if (e) throw new Error(e.message);
        if (alive) setReps((data ?? []) as SalesRep[]);
      } catch (e) {
        if (alive) setError(errText(e));
      }
    })();
    return () => { alive = false; };
  }, [company.id, loadStock]);

  const resetLines = useCallback(() => setLines([newLine(), newLine(), newLine()]), [newLine]);

  function changeType(t: PostType) {
    if (t === type) return;
    // A RETURN picks from what the rep holds, so its lines cannot be reused.
    if (t === 'RET' || type === 'RET') resetLines();
    setType(t);
    setError(null);
    if (t === 'RET') loadHoldings(repId).catch((e) => setError(errText(e)));
  }

  function changeRep(v: string) {
    setRepId(v);
    if (type === 'RET') {
      resetLines();
      loadHoldings(v).catch((e) => setError(errText(e)));
    }
  }

  const needsRep = type === 'ISS' || type === 'RET';
  const isGrn = type === 'GRN';

  const pickables = useMemo<Pickable[]>(() => {
    if (type === 'RET') {
      return holdings.map((h) => ({
        itemId: h.item_id, name: h.item_name, upc: h.units_per_case, price: Number(h.unit_price),
        available: h.qty_units_held, limited: true,
      }));
    }
    return (stock ?? [])
      .filter((s) => (type === 'AJUST' ? s.active || s.qty_units !== 0 : s.active))
      .map((s) => ({
        itemId: s.item_id, name: s.item_name, upc: s.units_per_case, price: Number(s.unit_price),
        available: s.qty_units, limited: type === 'ISS' || (type === 'AJUST' && direction === 'out'),
      }));
  }, [type, stock, holdings, direction]);

  const byId = useMemo(() => new Map(pickables.map((p) => [p.itemId, p])), [pickables]);

  /** Everything derived from one line: totals, value and whether it is acceptable. */
  const calc = useCallback((l: Line) => {
    const item = l.itemId !== null ? byId.get(l.itemId) ?? null : null;
    const cases = parseQty(l.cases);
    const units = parseQty(l.units);
    const free = isGrn ? parseQty(l.free) : 0;
    const discPct = isGrn ? parseAmount(l.discPct) : 0;
    const discAmt = isGrn ? parseAmount(l.discAmt) : 0;
    const bad = {
      cases: cases === null, units: units === null, free: free === null,
      discPct: discPct === null || (discPct ?? 0) > 100, discAmt: discAmt === null,
    };
    const invalid = Object.values(bad).some(Boolean);
    const total = item && !invalid ? (cases ?? 0) * item.upc + (units ?? 0) + (free ?? 0) : 0;
    const value = item && !invalid
      ? total * item.price * (1 - (discPct ?? 0) / 100) - (discAmt ?? 0)
      : 0;
    const over = !!item && item.limited && total > item.available;
    return { item, cases: cases ?? 0, units: units ?? 0, free: free ?? 0, discPct: discPct ?? 0, discAmt: discAmt ?? 0, bad, invalid, total, value, over };
  }, [byId, isGrn]);

  const totals = useMemo(() => {
    let count = 0, units = 0, value = 0;
    for (const l of lines) {
      const c = calc(l);
      if (!c.item || c.total === 0) continue;
      count++; units += c.total; value += c.value;
    }
    return { count, units, value };
  }, [lines, calc]);

  function updateLine(key: number, patch: Partial<Line>) {
    setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  }

  function chooseItem(itemId: number) {
    if (pickerFor === null) return;
    updateLine(pickerFor, { itemId });
    setPickerFor(null);
  }

  const usedItemIds = useMemo(() => new Set(lines.map((l) => l.itemId).filter((x): x is number => x !== null)), [lines]);

  async function submit() {
    setError(null);

    if (!date) return setError('Choose a date.');
    if (date > todaySL()) return setError('Date cannot be in the future.');
    if (needsRep && !repId) return setError('Select a sales rep.');
    if (type === 'AJUST' && !remarks.trim()) return setError('A stock adjustment needs a reason in Remarks.');

    const out: PostLine[] = [];
    let value = 0;
    for (const l of lines) {
      const c = calc(l);
      if (!c.item) continue;
      if (c.invalid) return setError(`Check the numbers entered for "${c.item.name}".`);
      if (c.total === 0) continue;
      if (c.value < 0) return setError(`Discount for "${c.item.name}" is larger than the line value.`);
      if (c.over) {
        return setError(
          type === 'RET'
            ? `"${c.item.name}": the rep holds ${fmtInt(c.item.available)} units, ${fmtInt(c.total)} entered.`
            : `"${c.item.name}": ${fmtInt(c.item.available)} units in stock, ${fmtInt(c.total)} entered.`,
        );
      }
      const sign = type === 'AJUST' && direction === 'out' ? -1 : 1;
      out.push({
        item_id: c.item.itemId,
        qty_cases: sign * c.cases,
        qty_units: sign * c.units,
        free_units: c.free,
        disc_pct: c.discPct,
        disc_amt: c.discAmt,
      });
      value += c.value;
    }
    if (out.length === 0) return setError('Add at least one item line with a quantity.');

    setBusy(true);
    try {
      // One call, one database transaction. The server re-checks everything
      // above against live stock; these checks only save a round trip.
      const { data, error: e } = await supabase().rpc('post_transaction', {
        p_company_id: company.id,
        p_type: type,
        p_date: date,
        p_rep_id: needsRep ? Number(repId) : null,
        p_remarks: remarks.trim() || null,
        p_lines: out,
      });
      if (e) throw new Error(e.message);
      setPosted({
        docNo: String(data),
        summary: `${TYPES.find((t) => t.type === type)?.label} · ${out.length} item${out.length > 1 ? 's' : ''} · ${fmtLKR(value)}`,
      });
      setRemarks('');
      resetLines();
      await loadStock();
      if (type === 'RET') await loadHoldings(repId);
    } catch (e) {
      setError(errText(e));
      // Stock may have changed under us (another user posted). Show fresh numbers.
      loadStock().catch(() => undefined);
    } finally {
      setBusy(false);
    }
  }

  function clearForm() {
    setRemarks('');
    setRepId('');
    setDate(todaySL());
    setHoldings([]);
    resetLines();
    setError(null);
  }

  const q = pickerSearch.trim().toLowerCase();
  const pickerRows = pickables.filter((p) => !q || p.name.toLowerCase().includes(q));
  const availLabel = type === 'RET' ? 'Held by rep' : 'In stock';
  const repOptions = type === 'ISS' ? reps.filter((r) => r.active) : reps;

  return (
    <>
      <PageHeader title="Post Transaction" sub={company.name}>
        <Link href="/transactions" className="btn">Transaction history</Link>
      </PageHeader>

      <div className="content">
        {error ? <Banner kind="error">{error}</Banner> : null}
        {!company.active ? <Banner kind="warn">This company is inactive. Posting is disabled.</Banner> : null}

        <div className="type-selector">
          {TYPES.filter((t) => !t.adminOnly || isAdmin).map((t) => (
            <button key={t.type} type="button" className={`type-btn ${t.type}` + (type === t.type ? ' active' : '')} onClick={() => changeType(t.type)}>
              <div className="type-label">{t.label}</div>
              <div className="type-desc">{t.desc}</div>
            </button>
          ))}
        </div>

        <div className="panel">
          <div className="panel-header"><span className="panel-title">Transaction Header</span></div>
          <div className="panel-body">
            <div className="form-grid">
              <div className="field">
                <span className="field-label">Doc No</span>
                <div className="readonly-box">Assigned when posted</div>
              </div>
              <div className="field">
                <label htmlFor="txDate">Date</label>
                <input id="txDate" type="date" value={date} max={todaySL()} onChange={(e) => setDate(e.target.value)} />
              </div>
              {needsRep ? (
                <div className="field">
                  <label htmlFor="rep">Sales Rep</label>
                  <select id="rep" value={repId} onChange={(e) => changeRep(e.target.value)}>
                    <option value="">Select rep</option>
                    {repOptions.map((r) => (
                      <option key={r.id} value={r.id}>{r.name}{r.active ? '' : ' (inactive)'}</option>
                    ))}
                  </select>
                </div>
              ) : null}
              {type === 'AJUST' ? (
                <div className="field">
                  <label htmlFor="dir">Direction</label>
                  <select id="dir" value={direction} onChange={(e) => setDirection(e.target.value as 'in' | 'out')}>
                    <option value="out">Remove from stock (damage, loss)</option>
                    <option value="in">Add to stock (found, count correction)</option>
                  </select>
                </div>
              ) : null}
              <div className="field full">
                <label htmlFor="remarks">Remarks{type === 'AJUST' ? ' (required: reason)' : ''}</label>
                <textarea id="remarks" rows={2} value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder={type === 'AJUST' ? 'Why is the stock being corrected?' : 'Optional notes'} />
              </div>
            </div>
          </div>
        </div>

        <div className="panel">
          <div className="panel-header">
            <span className="panel-title">Item Lines</span>
            <span className="panel-note">
              {type === 'RET' ? 'Only items this rep holds can be returned.' : 'Units per case and price are locked on the document when it is posted.'}
            </span>
          </div>
          <div className="table-wrap">
            <table className="table lines-table">
              <thead>
                <tr>
                  <th style={{ width: 32 }}>#</th>
                  <th>Item</th>
                  <th className="num">Cases</th>
                  <th className="num">Units</th>
                  {isGrn ? <th className="num">Free Units</th> : null}
                  {isGrn ? <th className="num">Disc %</th> : null}
                  {isGrn ? <th className="num">Disc Amt</th> : null}
                  <th className="num">Total Units</th>
                  <th className="num">Line Value</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {lines.map((l, idx) => {
                  const c = calc(l);
                  return (
                    <tr key={l.key}>
                      <td className="muted">{idx + 1}</td>
                      <td>
                        <div className="item-cell">
                          {c.item ? (
                            <>
                              <div style={{ flex: 1 }}>
                                <div className="item-cell-name">{c.item.name}</div>
                                <div className="item-cell-sub">
                                  LKR {fmtNum(c.item.price)} · {c.item.upc} per case · {availLabel.toLowerCase()}: {fmtInt(c.item.available)}
                                </div>
                              </div>
                              <button type="button" className="btn btn-sm" onClick={() => { setPickerSearch(''); setPickerFor(l.key); }}>Change</button>
                            </>
                          ) : (
                            <button
                              type="button" className="select-item-btn"
                              disabled={type === 'RET' && !repId}
                              onClick={() => { setPickerSearch(''); setPickerFor(l.key); }}
                            >
                              {type === 'RET' && !repId ? 'Select a rep first' : 'Select item'}
                            </button>
                          )}
                        </div>
                      </td>
                      <td className="num">
                        <input type="number" min={0} step={1} inputMode="numeric" placeholder="0" value={l.cases}
                          className={c.bad.cases || c.over ? 'invalid' : ''} onChange={(e) => updateLine(l.key, { cases: e.target.value })} />
                      </td>
                      <td className="num">
                        <input type="number" min={0} step={1} inputMode="numeric" placeholder="0" value={l.units}
                          className={c.bad.units || c.over ? 'invalid' : ''} onChange={(e) => updateLine(l.key, { units: e.target.value })} />
                      </td>
                      {isGrn ? (
                        <td className="num">
                          <input type="number" min={0} step={1} inputMode="numeric" placeholder="0" value={l.free}
                            className={c.bad.free ? 'invalid' : ''} onChange={(e) => updateLine(l.key, { free: e.target.value })} />
                        </td>
                      ) : null}
                      {isGrn ? (
                        <td className="num">
                          <input type="number" min={0} max={100} step="any" inputMode="decimal" placeholder="0" value={l.discPct}
                            className={c.bad.discPct ? 'invalid' : ''} onChange={(e) => updateLine(l.key, { discPct: e.target.value })} />
                        </td>
                      ) : null}
                      {isGrn ? (
                        <td className="num">
                          <input type="number" min={0} step="any" inputMode="decimal" placeholder="0" value={l.discAmt}
                            className={c.bad.discAmt ? 'invalid' : ''} onChange={(e) => updateLine(l.key, { discAmt: e.target.value })} />
                        </td>
                      ) : null}
                      <td className="num" style={c.over ? { color: 'var(--red)', fontWeight: 600 } : undefined}>
                        {c.item ? fmtInt(c.total) : '—'}
                      </td>
                      <td className="num" style={{ fontWeight: 600 }}>{c.item ? fmtLKR(c.value) : '—'}</td>
                      <td>
                        <button type="button" className="icon-btn" aria-label="Remove line"
                          onClick={() => setLines((ls) => (ls.length > 1 ? ls.filter((x) => x.key !== l.key) : [newLine()]))}>
                          &#10005;
                        </button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <button type="button" className="add-row-btn" onClick={() => setLines((ls) => [...ls, newLine()])}>+ Add item line</button>
          <div className="totals-bar">
            <span>Lines: <strong>{totals.count}</strong></span>
            <span>Total units: <strong>{fmtInt(totals.units)}</strong></span>
            <span>Transaction value: <strong>{fmtLKR(totals.value)}</strong></span>
          </div>
        </div>

        <div className="submit-area">
          <button type="button" className="btn btn-primary btn-lg" disabled={busy || !company.active} onClick={submit}>
            {busy ? 'Posting…' : 'Post Transaction'}
          </button>
          <button type="button" className="btn btn-lg" disabled={busy} onClick={clearForm}>Clear form</button>
        </div>
      </div>

      {pickerFor !== null ? (
        <Modal title="Select Item" wide flush onClose={() => setPickerFor(null)}>
          <div style={{ padding: '14px 24px', borderBottom: '1px solid var(--paper3)' }}>
            <input className="input" autoFocus placeholder="Search items…" value={pickerSearch} onChange={(e) => setPickerSearch(e.target.value)} />
          </div>
          <div className="picker-head">
            <span>Item</span>
            <span className="right">Unit price</span>
            <span className="right">Per case</span>
            <span className="right">{availLabel}</span>
          </div>
          {pickerRows.length === 0 ? (
            <div className="empty">
              {stock === null ? 'Loading…' : type === 'RET' ? 'This rep holds no stock.' : 'No items found.'}
            </div>
          ) : pickerRows.map((p) => {
            const current = lines.find((l) => l.key === pickerFor)?.itemId === p.itemId;
            const taken = usedItemIds.has(p.itemId) && !current;
            const none = p.limited && p.available <= 0;
            const level = p.available <= 0 ? 'out' : p.available < 2 * p.upc && type !== 'RET' ? 'low' : 'ok';
            return (
              <button key={p.itemId} type="button" className="picker-row" disabled={taken || none} onClick={() => chooseItem(p.itemId)}>
                <span>
                  <span style={{ fontWeight: 500 }}>{p.name}</span>
                  {taken ? <span className="muted" style={{ fontSize: 11, marginLeft: 6 }}>already on this document</span> : null}
                  {none && !taken ? <span style={{ fontSize: 11, marginLeft: 6, color: 'var(--red)' }}>no stock</span> : null}
                </span>
                <span className="right num">{fmtNum(p.price)}</span>
                <span className="right num">{p.upc}</span>
                <span className="right num">
                  {fmtInt(p.available)} <span className="muted">({fmtCases(p.available, p.upc)} cs)</span>{' '}
                  <span className={'pill ' + level}>{level.toUpperCase()}</span>
                </span>
              </button>
            );
          })}
        </Modal>
      ) : null}

      {posted ? (
        <Modal
          title="Posted"
          onClose={() => setPosted(null)}
          footer={
            <>
              <Link href="/transactions" className="btn">View history</Link>
              <button className="btn btn-primary" onClick={() => setPosted(null)}>Post another</button>
            </>
          }
        >
          <div style={{ textAlign: 'center' }}>
            <p className="muted" style={{ marginBottom: 12 }}>Transaction recorded. Stock balances are updated.</p>
            <div className="doc-no-big">{posted.docNo}</div>
            <p className="muted" style={{ marginTop: 12, fontSize: 13 }}>{posted.summary}</p>
          </div>
        </Modal>
      ) : null}
    </>
  );
}
