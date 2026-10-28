import { CalendarDays } from "lucide-react";
import { t } from "@/shared/i18n";
import { longDate, shortDate } from "@/shared/lib";

/** A readable timestamp keeps the exact date available on hover and to assistive technology. */
export function HostingDate({ value, published = false, label }: { value: string | number | null | undefined; published?: boolean; label?: "Opened {0}" | "Updated {0}" }) {
  const seconds = typeof value === "number" ? value : value ? Date.parse(value) / 1000 : NaN;
  if (!Number.isFinite(seconds)) return <span className="hosting-date">{t("Date unavailable")}</span>;
  const full = longDate(seconds), text = seconds > Date.now() / 1000 ? full : shortDate(seconds);
  const template = published ? "Published {0}" : label;
  return <time className="hosting-date" dateTime={new Date(seconds * 1000).toISOString()} title={full} aria-label={template ? t(template, full) : full}><CalendarDays size={12}/><span>{template ? t(template, text) : text}</span></time>;
}
