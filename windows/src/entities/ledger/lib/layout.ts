/** Tabs and compact filters sit above the view; the inspector becomes a sheet below 1,080 px and controls wrap below 640 px. */
export type LedgerLayout = "wide" | "medium" | "narrow";

export const LEDGER_WIDE = 1080;
export const LEDGER_NARROW = 640;

/** (macOS: LedgerWorkspaceView.layout(for:)) */
export const ledgerLayout = (width: number): LedgerLayout => (width >= LEDGER_WIDE ? "wide" : width >= LEDGER_NARROW ? "medium" : "narrow");
