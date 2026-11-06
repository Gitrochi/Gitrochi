import { language, t } from "@/shared/i18n";
import { shortDate } from "@/shared/lib";
import { dateStyle } from "./pull-request-page";

/** A request's dates as docs/design.md writes them: relative within a day, then "Yesterday", then "Oct 28". (macOS: PullRequestDate) */
export function requestDate(sec: number, now = Date.now() / 1000): string {
  const style = dateStyle(now - sec);
  if (style === "relative") return shortDate(sec);
  if (style === "yesterday") return t("Yesterday");
  return new Intl.DateTimeFormat(language, { month: "short", day: "numeric" }).format(new Date(sec * 1000));
}
