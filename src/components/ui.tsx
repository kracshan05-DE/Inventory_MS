'use client';

import { useEffect, type ReactNode } from 'react';

export function PageHeader({ title, sub, children }: { title: string; sub?: string; children?: ReactNode }) {
  return (
    <div className="topbar">
      <div>
        <h1>{title}</h1>
        {sub ? <div className="topbar-sub">{sub}</div> : null}
      </div>
      {children ? <div className="topbar-actions">{children}</div> : null}
    </div>
  );
}

export function Banner({ kind, children }: { kind: 'error' | 'success' | 'warn' | 'info'; children: ReactNode }) {
  return (
    <div className={'banner ' + kind} role={kind === 'error' ? 'alert' : 'status'}>
      <div>{children}</div>
    </div>
  );
}

export function Modal({
  title, onClose, children, footer, wide, flush,
}: {
  title: string; onClose: () => void; children: ReactNode; footer?: ReactNode; wide?: boolean; flush?: boolean;
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  return (
    <div className="modal-overlay" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className={'modal' + (wide ? ' wide' : '')} role="dialog" aria-modal="true" aria-label={title}>
        <div className="modal-header">
          <h3>{title}</h3>
          <button className="modal-close" onClick={onClose} aria-label="Close">&#10005;</button>
        </div>
        <div className={'modal-body' + (flush ? ' flush' : '')}>{children}</div>
        {footer ? <div className="modal-footer">{footer}</div> : null}
      </div>
    </div>
  );
}

export function Pagination({
  page, pageSize, total, onPage,
}: { page: number; pageSize: number; total: number; onPage: (p: number) => void }) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  const start = Math.max(1, Math.min(page - 2, pages - 4));
  const end = Math.min(pages, start + 4);
  const nums: number[] = [];
  for (let i = start; i <= end; i++) nums.push(i);
  return (
    <div className="pagination">
      <span>Page {page} of {pages} &middot; {total.toLocaleString()} records</span>
      <div className="page-btns">
        <button className="btn btn-sm" disabled={page <= 1} onClick={() => onPage(page - 1)}>Prev</button>
        {nums.map((n) => (
          <button key={n} className={'btn btn-sm' + (n === page ? ' btn-primary' : '')} onClick={() => onPage(n)}>{n}</button>
        ))}
        <button className="btn btn-sm" disabled={page >= pages} onClick={() => onPage(page + 1)}>Next</button>
      </div>
    </div>
  );
}

export function Loading({ cols }: { cols: number }) {
  return (
    <tr><td colSpan={cols} className="loading-row">Loading&hellip;</td></tr>
  );
}

export function Empty({ cols, children }: { cols: number; children: ReactNode }) {
  return (
    <tr><td colSpan={cols}><div className="empty">{children}</div></td></tr>
  );
}
