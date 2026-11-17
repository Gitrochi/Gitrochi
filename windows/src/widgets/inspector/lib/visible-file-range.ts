export const FILE_ROW_HEIGHT = 28;
/** A row and the 4px the board leaves under it */
export const FILE_ROW_PITCH = FILE_ROW_HEIGHT + 4;
const OVERSCAN_ROWS = 8;

/** A pane can briefly grow to its content height before SharedStack assigns its viewport. */
export function visibleFileRange(totalRows: number, offset: number, paneHeight: number, windowHeight: number, constrained = true): { first: number; last: number } {
  const height = constrained ? Math.min(Math.max(0, paneHeight), windowHeight > 0 ? windowHeight : 40 * FILE_ROW_PITCH) : Math.max(0, paneHeight);
  const first = Math.min(totalRows, Math.max(0, Math.floor(offset / FILE_ROW_PITCH) - OVERSCAN_ROWS));
  const last = Math.min(totalRows, Math.ceil((Math.max(0, offset) + height) / FILE_ROW_PITCH) + OVERSCAN_ROWS);
  return { first, last };
}
