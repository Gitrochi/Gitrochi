import type { LedgerInsights } from "../model/types";

const UNITS = [["day", 86_400_000], ["hour", 3_600_000], ["minute", 60_000], ["second", 1_000]] as const;

/**
 * A duration as the Insights sheet writes it: its largest unit and the next one when that is not zero, narrow and in the
 * screen language ("45s", "12m", "2h 10m", "3d"); "—" when there is none. (macOS: LedgerInsightFormat.duration)
 */
export function insightDuration(ms: number | undefined | null, locale: string): string {
  if (ms === undefined || ms === null || !Number.isFinite(ms)) return "—";
  const total = Math.max(0, Math.floor(ms / 1_000) * 1_000);
  const format = (unit: (typeof UNITS)[number][0], n: number) => new Intl.NumberFormat(locale, { style: "unit", unit, unitDisplay: "narrow" }).format(n);
  const at = UNITS.findIndex(([, size]) => total >= size);
  if (at < 0) return format("second", 0);
  const [unit, size] = UNITS[at];
  const big = Math.floor(total / size);
  const parts = [format(unit, big)];
  const next = UNITS[at + 1];
  if (next) {
    const small = Math.floor((total - big * size) / next[1]);
    if (small) parts.push(format(next[0], small));
  }
  return parts.join(" ");
}

/** Nothing happened in the period: the sheet shows its empty state instead of zeros (macOS: LedgerInsights.isEmpty) */
export function insightsEmpty(i: LedgerInsights): boolean {
  return !i.sessions.total && !i.reports && !i.questions.asked && !i.questions.open.count && !i.autoAnswers.total;
}

/** A bar's length as a share of the group's largest value, in percent; a value above zero always shows */
export function barShare(value: number, max: number): number {
  return value > 0 ? Math.min(100, Math.max(2, (100 * value) / Math.max(1, max))) : 0;
}
