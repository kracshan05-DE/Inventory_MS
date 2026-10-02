/** All dates and times are shown in Sri Lanka time, whatever the device is set to. */
export const SL_TZ = 'Asia/Colombo';

/** Today in Sri Lanka as YYYY-MM-DD. */
export function todaySL(): string {
  return new Date().toLocaleDateString('en-CA', { timeZone: SL_TZ });
}

/** First day of the current month in Sri Lanka as YYYY-MM-DD. */
export function firstOfMonthSL(): string {
  return todaySL().slice(0, 8) + '01';
}

const lkr = new Intl.NumberFormat('en-LK', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const int = new Intl.NumberFormat('en-LK', { maximumFractionDigits: 0 });

export function fmtNum(n: number | string | null | undefined): string {
  return lkr.format(Number(n ?? 0));
}
export function fmtLKR(n: number | string | null | undefined): string {
  return 'LKR ' + fmtNum(n);
}
export function fmtInt(n: number | string | null | undefined): string {
  return int.format(Number(n ?? 0));
}
/** Units shown as cases, one decimal. */
export function fmtCases(units: number, unitsPerCase: number): string {
  if (!unitsPerCase) return '-';
  return (units / unitsPerCase).toFixed(1);
}
/** "+5" / "-3" / "0" */
export function fmtSigned(n: number): string {
  return (n > 0 ? '+' : '') + fmtInt(n);
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** A DATE column (YYYY-MM-DD) as "02 Oct 2026". Pure string work, so no timezone shift. */
export function fmtDate(d: string | null | undefined): string {
  if (!d) return '-';
  const [y, m, day] = d.split('-');
  const month = MONTHS[Number(m) - 1];
  if (!y || !month || !day) return d;
  return `${day.slice(0, 2)} ${month} ${y}`;
}

/** A timestamp as Sri Lanka local date and time. */
export function fmtDateTime(ts: string | null | undefined): string {
  if (!ts) return '-';
  // sv-SE gives "2026-10-02 21:03" in the requested zone on every browser.
  const iso = new Date(ts).toLocaleString('sv-SE', {
    timeZone: SL_TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  });
  const [date, time] = iso.split(' ');
  return `${fmtDate(date)}, ${time ?? ''}`.trim();
}

/** Start and end of a Sri Lanka calendar day as timestamps, for filtering timestamptz columns. */
export function dayStartSL(d: string): string { return `${d}T00:00:00+05:30`; }
export function dayEndSL(d: string): string { return `${d}T23:59:59.999+05:30`; }

/** Parses a quantity typed into a form. Empty = 0. Returns null if not a whole number >= 0. */
export function parseQty(s: string): number | null {
  const t = s.trim();
  if (t === '') return 0;
  if (!/^\d+$/.test(t)) return null;
  const n = Number(t);
  return Number.isSafeInteger(n) ? n : null;
}

/** Parses a non-negative decimal (price, discount). Empty = 0. */
export function parseAmount(s: string): number | null {
  const t = s.trim();
  if (t === '') return 0;
  if (!/^\d+(\.\d+)?$/.test(t)) return null;
  return Number(t);
}
