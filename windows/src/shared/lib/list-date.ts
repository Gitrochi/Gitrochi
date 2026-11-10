import { language, t } from "@/shared/i18n";

/**
 * How a list row dates its item (docs/design.md, Dates): within 24 hours "12m ago" or "2h ago", then "Yesterday",
 * then the day, with the year only for another year. Times are in seconds. (macOS: Core/ListDate.swift)
 */
export function listWhen(at: number, now = Date.now() / 1000, lang: string = language): string {
  const elapsed = now - at;
  if (elapsed < 60) return t("Just now");
  if (elapsed < 3600) return t("{0}m ago", Math.floor(elapsed / 60));
  if (elapsed < 86_400) return t("{0}h ago", Math.floor(elapsed / 3600));
  const day = (seconds: number) => { const d = new Date(seconds * 1000); return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()); };
  return Math.round((day(now) - day(at)) / 86_400_000) <= 1 ? t("Yesterday") : listDay(at, now, lang);
}

/** "Oct 28", or "Dec 30, 2025" for another year */
export function listDay(at: number, now = Date.now() / 1000, lang: string = language): string {
  const date = new Date(at * 1000), sameYear = date.getFullYear() === new Date(now * 1000).getFullYear();
  return new Intl.DateTimeFormat(lang, { month: "short", day: "numeric", ...(sameYear ? {} : { year: "numeric" }) }).format(date);
}
