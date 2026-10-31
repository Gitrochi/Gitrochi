/** Baseline versions compare as numeric tuples (1.10.0 > 1.9.2); text that is not a number compares as text. (macOS: LedgerVersion.compare) */
export function compareVersions(a: string, b: string): number {
  const pa = a.replace(/^v/i, "").split(/[.\-+]/), pb = b.replace(/^v/i, "").split(/[.\-+]/);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] ?? "", y = pb[i] ?? "";
    const nx = /^\d+$/.test(x) ? Number(x) : NaN, ny = /^\d+$/.test(y) ? Number(y) : NaN;
    const d = !Number.isNaN(nx) && !Number.isNaN(ny) ? nx - ny : x.localeCompare(y);
    if (d) return d;
  }
  return 0;
}
