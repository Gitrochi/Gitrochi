/** The page's columns: filters | view | inspector when wide; the inspector becomes a sheet below 1,080 px and the filters stack above the view below 700 px */
export type LedgerLayout = "wide" | "medium" | "narrow";

export const LEDGER_WIDE = 1080;
export const LEDGER_NARROW = 700;

/** (macOS: LedgerWorkspaceView.layout(for:)) */
export const ledgerLayout = (width: number): LedgerLayout => (width >= LEDGER_WIDE ? "wide" : width >= LEDGER_NARROW ? "medium" : "narrow");
