type Cell = string | number | boolean | null | undefined;

function cell(v: Cell): string {
  if (v === null || v === undefined) return '';
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  let s = v;
  // A text cell starting with = + - @ is run as a formula by Excel. Neutralise it.
  if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
  return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}

/** Downloads rows as a CSV file that Excel opens directly (UTF-8 with BOM). */
export function downloadCsv(filename: string, rows: Record<string, Cell>[]): void {
  const first = rows[0];
  if (!first) return;
  const headers = Object.keys(first);
  const lines = [headers.map(cell).join(',')];
  for (const r of rows) lines.push(headers.map((h) => cell(r[h])).join(','));
  const blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

/** "Unilever" -> "unilever", safe for file names. */
export function slug(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '') || 'export';
}
