'use client';

import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react';
import { useSession } from '@/components/SessionProvider';
import { Banner, Empty, Loading, Modal, PageHeader } from '@/components/ui';
import { fmtDate, fmtInt, fmtNum, parseAmount, parseQty } from '@/lib/format';
import { errText, fetchAll, supabase } from '@/lib/supabase';
import type { Company, Profile, Role, SalesRep, StockRow } from '@/lib/types';

type Tab = 'items' | 'reps' | 'companies' | 'users';
type Msg = { kind: 'error' | 'success'; text: string } | null;

/** Turns database constraint errors into something a person can act on. */
function friendly(e: unknown): string {
  const m = errText(e);
  if (/duplicate key|already exists/i.test(m)) return 'That name is already in use.';
  if (/row-level security|permission denied/i.test(m)) return 'Only an admin can change this.';
  return m;
}

export default function SettingsPage() {
  const { isAdmin, company } = useSession();
  const [tab, setTab] = useState<Tab>('items');

  if (!isAdmin) {
    return (
      <>
        <PageHeader title="Settings" />
        <div className="content"><Banner kind="info">Settings are available to admins only.</Banner></div>
      </>
    );
  }

  return (
    <>
      <PageHeader title="Settings" sub={tab === 'items' || tab === 'reps' ? company.name : 'All companies'} />
      <div className="content">
        <div className="tabs">
          <button className={'tab-btn' + (tab === 'items' ? ' active' : '')} onClick={() => setTab('items')}>Items</button>
          <button className={'tab-btn' + (tab === 'reps' ? ' active' : '')} onClick={() => setTab('reps')}>Sales Reps</button>
          <button className={'tab-btn' + (tab === 'companies' ? ' active' : '')} onClick={() => setTab('companies')}>Companies</button>
          <button className={'tab-btn' + (tab === 'users' ? ' active' : '')} onClick={() => setTab('users')}>Users</button>
        </div>
        {tab === 'items' ? <ItemsTab /> : null}
        {tab === 'reps' ? <RepsTab /> : null}
        {tab === 'companies' ? <CompaniesTab /> : null}
        {tab === 'users' ? <UsersTab /> : null}
      </div>
    </>
  );
}

/* ------------------------------------------------------------------ */
/* Items                                                               */
/* ------------------------------------------------------------------ */

function ItemsTab() {
  const { company } = useSession();
  const [items, setItems] = useState<StockRow[] | null>(null);
  const [search, setSearch] = useState('');
  const [msg, setMsg] = useState<Msg>(null);
  const [busy, setBusy] = useState(false);

  const [editId, setEditId] = useState<number | null>(null);
  const [name, setName] = useState('');
  const [upc, setUpc] = useState('');
  const [price, setPrice] = useState('');
  const [active, setActive] = useState('true');

  const load = useCallback(async () => {
    const sb = supabase();
    const rows = await fetchAll<StockRow>((f, t) =>
      sb.from('v_stock').select('*').eq('company_id', company.id).order('item_name').range(f, t),
    );
    setItems(rows);
  }, [company.id]);

  useEffect(() => {
    load().catch((e) => setMsg({ kind: 'error', text: errText(e) }));
  }, [load]);

  function clear() {
    setEditId(null); setName(''); setUpc(''); setPrice(''); setActive('true');
  }
  function edit(i: StockRow) {
    setEditId(i.item_id); setName(i.item_name); setUpc(String(i.units_per_case)); setPrice(String(i.unit_price)); setActive(String(i.active));
    setMsg(null);
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  async function save(e: FormEvent) {
    e.preventDefault();
    const n = name.trim();
    const u = parseQty(upc);
    const p = parseAmount(price);
    if (!n) return setMsg({ kind: 'error', text: 'Item name is required.' });
    if (u === null || u < 1) return setMsg({ kind: 'error', text: 'Units per case must be a whole number, 1 or more.' });
    if (p === null) return setMsg({ kind: 'error', text: 'Unit price must be a number, 0 or more.' });

    setBusy(true);
    const row = { name: n, units_per_case: u, unit_price: p, active: active === 'true' };
    const sb = supabase();
    const { error } = editId
      ? await sb.from('items').update(row).eq('id', editId)
      : await sb.from('items').insert({ ...row, company_id: company.id });
    setBusy(false);
    if (error) return setMsg({ kind: 'error', text: friendly(error) });
    setMsg({ kind: 'success', text: editId ? `"${n}" updated.` : `"${n}" added.` });
    clear();
    load().catch((err) => setMsg({ kind: 'error', text: errText(err) }));
  }

  async function toggle(i: StockRow) {
    const { error } = await supabase().from('items').update({ active: !i.active }).eq('id', i.item_id);
    if (error) return setMsg({ kind: 'error', text: friendly(error) });
    load().catch((err) => setMsg({ kind: 'error', text: errText(err) }));
  }

  const q = search.trim().toLowerCase();
  const list = (items ?? []).filter((i) => !q || i.item_name.toLowerCase().includes(q));

  return (
    <>
      {msg ? <Banner kind={msg.kind}>{msg.text}</Banner> : null}
      <div className="two-col">
        <div className="panel">
          <div className="panel-header">
            <span className="panel-title">{editId ? 'Edit item' : 'Add new item'}</span>
            {editId ? <button className="btn btn-sm" onClick={clear}>Cancel edit</button> : null}
          </div>
          <form className="panel-body stack" onSubmit={save} noValidate>
            <div className="field"><span className="field-label">Company</span><div className="readonly-box">{company.name}</div></div>
            <div className="field"><label htmlFor="iName">Item name</label><input id="iName" type="text" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. COMFORT 160/=" /></div>
            <div className="field"><label htmlFor="iUpc">Units per case</label><input id="iUpc" type="number" min={1} step={1} value={upc} onChange={(e) => setUpc(e.target.value)} placeholder="e.g. 48" /></div>
            <div className="field"><label htmlFor="iPrice">Unit price (LKR)</label><input id="iPrice" type="number" min={0} step="any" value={price} onChange={(e) => setPrice(e.target.value)} placeholder="e.g. 145.45" /></div>
            <div className="field">
              <label htmlFor="iActive">Status</label>
              <select id="iActive" value={active} onChange={(e) => setActive(e.target.value)}><option value="true">Active</option><option value="false">Inactive</option></select>
            </div>
            {editId ? (
              <div className="field-hint">
                Changing the price or units per case applies to new documents only. Posted documents keep the values they were posted with.
              </div>
            ) : null}
            <button type="submit" className="btn btn-primary" disabled={busy}>{busy ? 'Saving…' : editId ? 'Save changes' : 'Add item'}</button>
          </form>
        </div>

        <div className="panel">
          <div className="panel-header">
            <span className="panel-title">Items <span className="muted" style={{ fontWeight: 400 }}>({list.length})</span></span>
            <input className="search" placeholder="Search items…" value={search} onChange={(e) => setSearch(e.target.value)} />
          </div>
          <div className="table-scroll">
            <table className="table">
              <thead><tr><th>Item</th><th className="num">Per case</th><th className="num">Unit price</th><th className="num">Stock (units)</th><th>Status</th><th /></tr></thead>
              <tbody>
                {items === null ? <Loading cols={6} /> : list.length === 0 ? <Empty cols={6}>No items found.</Empty> : list.map((i) => (
                  <tr key={i.item_id}>
                    <td style={{ fontWeight: 500 }}>{i.item_name}</td>
                    <td className="num">{i.units_per_case}</td>
                    <td className="num">{fmtNum(i.unit_price)}</td>
                    <td className="num" style={{ fontWeight: 600, color: i.low_stock ? 'var(--red)' : 'var(--green)' }}>{fmtInt(i.qty_units)}</td>
                    <td><span className={'pill ' + (i.active ? 'active' : 'inactive')}>{i.active ? 'ACTIVE' : 'INACTIVE'}</span></td>
                    <td className="right nowrap">
                      <button className="btn btn-sm" onClick={() => edit(i)}>Edit</button>{' '}
                      <button className={'btn btn-sm' + (i.active ? ' btn-danger' : '')} onClick={() => toggle(i)}>{i.active ? 'Deactivate' : 'Activate'}</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </>
  );
}

/* ------------------------------------------------------------------ */
/* Sales reps                                                          */
/* ------------------------------------------------------------------ */

function RepsTab() {
  const { company } = useSession();
  const [reps, setReps] = useState<SalesRep[] | null>(null);
  const [msg, setMsg] = useState<Msg>(null);
  const [busy, setBusy] = useState(false);
  const [editId, setEditId] = useState<number | null>(null);
  const [name, setName] = useState('');
  const [active, setActive] = useState('true');

  const load = useCallback(async () => {
    const { data, error } = await supabase().from('sales_reps').select('id,company_id,name,active').eq('company_id', company.id).order('name');
    if (error) throw new Error(error.message);
    setReps((data ?? []) as SalesRep[]);
  }, [company.id]);

  useEffect(() => {
    load().catch((e) => setMsg({ kind: 'error', text: errText(e) }));
  }, [load]);

  function clear() { setEditId(null); setName(''); setActive('true'); }

  async function save(e: FormEvent) {
    e.preventDefault();
    const n = name.trim();
    if (!n) return setMsg({ kind: 'error', text: 'Rep name is required.' });
    setBusy(true);
    const sb = supabase();
    const row = { name: n, active: active === 'true' };
    const { error } = editId
      ? await sb.from('sales_reps').update(row).eq('id', editId)
      : await sb.from('sales_reps').insert({ ...row, company_id: company.id });
    setBusy(false);
    if (error) return setMsg({ kind: 'error', text: friendly(error) });
    setMsg({ kind: 'success', text: editId ? `"${n}" updated.` : `"${n}" added.` });
    clear();
    load().catch((err) => setMsg({ kind: 'error', text: errText(err) }));
  }

  async function toggle(r: SalesRep) {
    const { error } = await supabase().from('sales_reps').update({ active: !r.active }).eq('id', r.id);
    if (error) return setMsg({ kind: 'error', text: friendly(error) });
    load().catch((err) => setMsg({ kind: 'error', text: errText(err) }));
  }

  return (
    <>
      {msg ? <Banner kind={msg.kind}>{msg.text}</Banner> : null}
      <div className="two-col">
        <div className="panel">
          <div className="panel-header">
            <span className="panel-title">{editId ? 'Edit sales rep' : 'Add sales rep'}</span>
            {editId ? <button className="btn btn-sm" onClick={clear}>Cancel edit</button> : null}
          </div>
          <form className="panel-body stack" onSubmit={save} noValidate>
            <div className="field"><span className="field-label">Company</span><div className="readonly-box">{company.name}</div></div>
            <div className="field"><label htmlFor="rName">Rep name</label><input id="rName" type="text" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Saji" /></div>
            <div className="field">
              <label htmlFor="rActive">Status</label>
              <select id="rActive" value={active} onChange={(e) => setActive(e.target.value)}><option value="true">Active</option><option value="false">Inactive</option></select>
            </div>
            <button type="submit" className="btn btn-primary" disabled={busy}>{busy ? 'Saving…' : editId ? 'Save changes' : 'Add rep'}</button>
          </form>
        </div>

        <div className="panel">
          <div className="panel-header"><span className="panel-title">Sales reps <span className="muted" style={{ fontWeight: 400 }}>({reps?.length ?? 0})</span></span></div>
          <div className="table-scroll">
            <table className="table">
              <thead><tr><th>Name</th><th>Status</th><th /></tr></thead>
              <tbody>
                {reps === null ? <Loading cols={3} /> : reps.length === 0 ? <Empty cols={3}>No reps yet.</Empty> : reps.map((r) => (
                  <tr key={r.id}>
                    <td style={{ fontWeight: 500 }}>{r.name}</td>
                    <td><span className={'pill ' + (r.active ? 'active' : 'inactive')}>{r.active ? 'ACTIVE' : 'INACTIVE'}</span></td>
                    <td className="right nowrap">
                      <button className="btn btn-sm" onClick={() => { setEditId(r.id); setName(r.name); setActive(String(r.active)); setMsg(null); }}>Edit</button>{' '}
                      <button className={'btn btn-sm' + (r.active ? ' btn-danger' : '')} onClick={() => toggle(r)}>{r.active ? 'Deactivate' : 'Activate'}</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </>
  );
}

/* ------------------------------------------------------------------ */
/* Companies                                                           */
/* ------------------------------------------------------------------ */

function CompaniesTab() {
  const { companies, reloadCompanies } = useSession();
  const [msg, setMsg] = useState<Msg>(null);
  const [busy, setBusy] = useState(false);
  const [editId, setEditId] = useState<number | null>(null);
  const [name, setName] = useState('');
  const [active, setActive] = useState('true');

  function clear() { setEditId(null); setName(''); setActive('true'); }

  async function save(e: FormEvent) {
    e.preventDefault();
    const n = name.trim();
    if (!n) return setMsg({ kind: 'error', text: 'Company name is required.' });
    setBusy(true);
    const sb = supabase();
    const row = { name: n, active: active === 'true' };
    const { error } = editId ? await sb.from('companies').update(row).eq('id', editId) : await sb.from('companies').insert(row);
    setBusy(false);
    if (error) return setMsg({ kind: 'error', text: friendly(error) });
    setMsg({ kind: 'success', text: editId ? `"${n}" updated.` : `"${n}" added. It is now in the company switcher.` });
    clear();
    reloadCompanies().catch((err) => setMsg({ kind: 'error', text: errText(err) }));
  }

  async function toggle(c: Company) {
    const { error } = await supabase().from('companies').update({ active: !c.active }).eq('id', c.id);
    if (error) return setMsg({ kind: 'error', text: friendly(error) });
    reloadCompanies().catch((err) => setMsg({ kind: 'error', text: errText(err) }));
  }

  return (
    <>
      {msg ? <Banner kind={msg.kind}>{msg.text}</Banner> : null}
      <div className="two-col">
        <div className="panel">
          <div className="panel-header">
            <span className="panel-title">{editId ? 'Edit company' : 'Add company'}</span>
            {editId ? <button className="btn btn-sm" onClick={clear}>Cancel edit</button> : null}
          </div>
          <form className="panel-body stack" onSubmit={save} noValidate>
            <div className="field"><label htmlFor="cName">Company name</label><input id="cName" type="text" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Nestle" /></div>
            <div className="field">
              <label htmlFor="cActive">Status</label>
              <select id="cActive" value={active} onChange={(e) => setActive(e.target.value)}><option value="true">Active</option><option value="false">Inactive</option></select>
            </div>
            <div className="field-hint">An inactive company keeps all its history and reports. Posting to it is blocked.</div>
            <button type="submit" className="btn btn-primary" disabled={busy}>{busy ? 'Saving…' : editId ? 'Save changes' : 'Add company'}</button>
          </form>
        </div>

        <div className="panel">
          <div className="panel-header"><span className="panel-title">Companies <span className="muted" style={{ fontWeight: 400 }}>({companies.length})</span></span></div>
          <div className="table-wrap">
            <table className="table">
              <thead><tr><th>Company</th><th>ID</th><th>Status</th><th>Created</th><th /></tr></thead>
              <tbody>
                {companies.map((c) => (
                  <tr key={c.id}>
                    <td style={{ fontWeight: 500 }}>{c.name}</td>
                    <td className="mono muted">{c.id}</td>
                    <td><span className={'pill ' + (c.active ? 'active' : 'inactive')}>{c.active ? 'ACTIVE' : 'INACTIVE'}</span></td>
                    <td className="muted" style={{ fontSize: 12 }}>{fmtDate(c.created_at?.slice(0, 10))}</td>
                    <td className="right nowrap">
                      <button className="btn btn-sm" onClick={() => { setEditId(c.id); setName(c.name); setActive(String(c.active)); setMsg(null); }}>Edit</button>{' '}
                      <button className={'btn btn-sm' + (c.active ? ' btn-danger' : '')} onClick={() => toggle(c)}>{c.active ? 'Deactivate' : 'Activate'}</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </>
  );
}

/* ------------------------------------------------------------------ */
/* Users                                                               */
/* ------------------------------------------------------------------ */

function UsersTab() {
  const { companies, userId } = useSession();
  const [users, setUsers] = useState<Profile[] | null>(null);
  const [access, setAccess] = useState<Record<string, number[]>>({});
  const [msg, setMsg] = useState<Msg>(null);

  const [editing, setEditing] = useState<Profile | null>(null);
  const [fullName, setFullName] = useState('');
  const [role, setRole] = useState<Role>('user');
  const [picked, setPicked] = useState<Set<number>>(new Set());
  const [busy, setBusy] = useState(false);
  const [modalError, setModalError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const sb = supabase();
    const [u, a] = await Promise.all([
      sb.from('user_profiles').select('id,full_name,role,company_id').order('full_name'),
      sb.from('user_company_access').select('user_id,company_id'),
    ]);
    if (u.error) throw new Error(u.error.message);
    if (a.error) throw new Error(a.error.message);
    const map: Record<string, number[]> = {};
    for (const r of (a.data ?? []) as { user_id: string; company_id: number }[]) (map[r.user_id] ??= []).push(r.company_id);
    setUsers((u.data ?? []) as Profile[]);
    setAccess(map);
  }, []);

  useEffect(() => {
    load().catch((e) => setMsg({ kind: 'error', text: errText(e) }));
  }, [load]);

  const companyName = useMemo(() => new Map(companies.map((c) => [c.id, c.name])), [companies]);

  function open(u: Profile) {
    setEditing(u);
    setFullName(u.full_name);
    setRole(u.role);
    setPicked(new Set(access[u.id] ?? []));
    setModalError(null);
  }

  async function save() {
    if (!editing) return;
    const n = fullName.trim();
    if (!n) return setModalError('Name is required.');
    setBusy(true);
    setModalError(null);
    try {
      const sb = supabase();
      const { error } = await sb.from('user_profiles').update({ full_name: n, role }).eq('id', editing.id);
      if (error) throw error;

      const before = new Set(access[editing.id] ?? []);
      const add = [...picked].filter((c) => !before.has(c));
      const remove = [...before].filter((c) => !picked.has(c));
      if (add.length) {
        const r = await sb.from('user_company_access').insert(add.map((c) => ({ user_id: editing.id, company_id: c })));
        if (r.error) throw r.error;
      }
      if (remove.length) {
        const r = await sb.from('user_company_access').delete().eq('user_id', editing.id).in('company_id', remove);
        if (r.error) throw r.error;
      }
      setMsg({ kind: 'success', text: `${n} updated.` });
      setEditing(null);
      await load();
    } catch (e) {
      setModalError(friendly(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      {msg ? <Banner kind={msg.kind}>{msg.text}</Banner> : null}
      <Banner kind="info">
        <strong>To add a person:</strong> in the Supabase dashboard open Authentication, Users, Add user, and set their email and
        password. They appear here as a User with no access. Then use Edit to choose their role and companies.
        Admins can open every company, post adjustments, reverse documents and change settings.
      </Banner>

      <div className="panel">
        <div className="panel-header"><span className="panel-title">Users <span className="muted" style={{ fontWeight: 400 }}>({users?.length ?? 0})</span></span></div>
        <div className="table-wrap">
          <table className="table">
            <thead><tr><th>Name</th><th>Role</th><th>Company access</th><th /></tr></thead>
            <tbody>
              {users === null ? <Loading cols={4} /> : users.length === 0 ? <Empty cols={4}>No users.</Empty> : users.map((u) => {
                const ids = access[u.id] ?? [];
                return (
                  <tr key={u.id}>
                    <td style={{ fontWeight: 500 }}>{u.full_name}{u.id === userId ? <span className="muted" style={{ fontWeight: 400 }}> (you)</span> : null}</td>
                    <td><span className={'pill ' + (u.role === 'admin' ? 'admin' : 'inactive')}>{u.role.toUpperCase()}</span></td>
                    <td>
                      {u.role === 'admin' ? <span className="muted">All companies</span>
                        : ids.length === 0 ? <span style={{ color: 'var(--red)' }}>None: cannot use the app yet</span>
                        : ids.map((c) => companyName.get(c) ?? `#${c}`).sort().join(', ')}
                    </td>
                    <td className="right"><button className="btn btn-sm" onClick={() => open(u)}>Edit</button></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      {editing ? (
        <Modal
          title="Edit user"
          onClose={() => (busy ? undefined : setEditing(null))}
          footer={
            <>
              <button className="btn" disabled={busy} onClick={() => setEditing(null)}>Cancel</button>
              <button className="btn btn-primary" disabled={busy} onClick={save}>{busy ? 'Saving…' : 'Save'}</button>
            </>
          }
        >
          {modalError ? <Banner kind="error">{modalError}</Banner> : null}
          <div className="stack">
            <div className="field"><label htmlFor="uName">Name</label><input id="uName" type="text" value={fullName} onChange={(e) => setFullName(e.target.value)} /></div>
            <div className="field">
              <label htmlFor="uRole">Role</label>
              <select id="uRole" value={role} disabled={editing.id === userId} onChange={(e) => setRole(e.target.value as Role)}>
                <option value="user">User</option><option value="admin">Admin</option>
              </select>
              {editing.id === userId ? <span className="field-hint">You cannot change your own role. Ask another admin.</span> : null}
            </div>
            <div className="field">
              <span className="field-label">Company access</span>
              {role === 'admin' ? <div className="readonly-box">Admins can open every company.</div> : companies.map((c) => (
                <label key={c.id} className="check-row">
                  <input type="checkbox" checked={picked.has(c.id)} onChange={(e) => setPicked((s) => { const n = new Set(s); if (e.target.checked) n.add(c.id); else n.delete(c.id); return n; })} />
                  {c.name}{c.active ? '' : ' (inactive)'}
                </label>
              ))}
            </div>
          </div>
        </Modal>
      ) : null}
    </>
  );
}
