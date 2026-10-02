// Row shapes of the tables and views the app reads.
// numeric columns arrive from PostgREST as numbers.

export type TxType = 'GRN' | 'ISS' | 'RET' | 'SALE' | 'AJUST' | 'REV';
export type TxStatus = 'active' | 'reversed';
export type Role = 'admin' | 'user';

export const TX_LABEL: Record<TxType, string> = {
  GRN: 'GRN',
  ISS: 'ISSUE',
  RET: 'RETURN',
  SALE: 'SETTLED',
  AJUST: 'ADJUST',
  REV: 'REVERSAL',
};

export interface Company { id: number; name: string; active: boolean; created_at: string }
export interface Profile { id: string; full_name: string; role: Role; company_id: number | null }
export interface Item { id: number; company_id: number; name: string; units_per_case: number; unit_price: number; active: boolean }
export interface SalesRep { id: number; company_id: number; name: string; active: boolean }

export interface StockRow {
  company_id: number; item_id: number; item_name: string; units_per_case: number; unit_price: number;
  active: boolean; qty_units: number; qty_cases: number; stock_value: number; low_stock: boolean;
  last_updated: string | null;
}

export interface TxDocument {
  doc_no: string; company_id: number; date: string; type: TxType; status: TxStatus;
  rep_id: number | null; rep_name: string | null; remarks: string | null;
  posted_by: string | null; posted_by_name: string | null; created_at: string;
  reversed_by: string | null; reversal_of: string | null;
  line_count: number; total_units: number; gross_value: number; doc_value: number; item_ids: number[];
}

export interface TxLine {
  line_id: number; doc_no: string; company_id: number; date: string; type: TxType; status: TxStatus;
  rep_id: number | null; rep_name: string | null; remarks: string | null; posted_by_name: string | null;
  created_at: string; item_id: number; item_name: string;
  qty_cases: number; qty_units: number; free_units: number; units_per_case: number; total_units: number;
  unit_price: number; disc_pct: number; disc_amt: number; gross_value: number; line_value: number;
}

export interface RepSummary {
  company_id: number; rep_id: number; rep_name: string; active: boolean;
  issued_units: number; returned_units: number; sold_units: number;
  issued_value: number; returned_value: number; sold_value: number;
  item_count: number; held_units: number; held_value: number;
}

export interface RepHolding {
  company_id: number; rep_id: number; rep_name: string; item_id: number; item_name: string;
  units_per_case: number; unit_price: number; qty_units_held: number; held_value: number;
}

export interface ReconRow {
  company_id: number; item_id: number; item_name: string; units_per_case: number; unit_price: number; active: boolean;
  grn_units: number; adjust_units: number; issued_units: number; returned_units: number; sold_units: number;
  grn_value: number; issued_value: number; returned_value: number; sold_value: number;
  opening_stock_units: number; opening_rep_units: number;
  stock_units: number; expected_stock_units: number; stock_variance: number;
  rep_units: number; expected_rep_units: number; rep_variance: number;
  stock_value: number; rep_value: number;
}

export interface AuditRow {
  id: number; company_id: number | null; user_id: string | null; action: string; table_name: string;
  record_id: string | null; old_data: unknown; new_data: unknown; created_at: string;
}

export interface TxSummary {
  doc_count: number; grn_value: number; issued_value: number; returned_value: number; sold_value: number;
}

/** One line sent to post_transaction(). */
export interface PostLine {
  item_id: number; qty_cases: number; qty_units: number; free_units: number; disc_pct: number; disc_amt: number;
}
