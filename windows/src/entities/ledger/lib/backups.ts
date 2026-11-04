/** How many backups Settings › Ledger lists before "Show all" (macOS: LedgerSettings.restoreSection) */
export const BACKUPS_SHOWN = 5;

/**
 * A backup's size in decimal units, as macOS's ByteCountFormatter (file style) writes it: bytes, kB, then MB and GB
 * with at most one decimal, in the screen language.
 */
export function backupSize(bytes: number, locale: string): string {
  const units = [["byte", 1], ["kilobyte", 1e3], ["megabyte", 1e6], ["gigabyte", 1e9]] as const;
  const [unit, size] = [...units].reverse().find(([, step]) => bytes >= step) ?? units[0];
  const value = bytes / size;
  return new Intl.NumberFormat(locale, { style: "unit", unit, unitDisplay: unit === "byte" ? "long" : "short", maximumFractionDigits: unit === "byte" || unit === "kilobyte" ? 0 : 1 }).format(value);
}

/** The newest few backups, or all of them when asked for */
export function shownBackups<T>(files: readonly T[], all: boolean, limit = BACKUPS_SHOWN): T[] {
  return all ? [...files] : files.slice(0, limit);
}
