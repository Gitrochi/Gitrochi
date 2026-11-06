import type { AccountWorkItem } from "@/entities/hosting";
import { t } from "@/shared/i18n";

/**
 * What the Account page says about a notification or a piece of open work (the redesign's Account board): why it is
 * in the inbox, when it changed, and which rows the search, the unread filter and the sort order leave.
 * (macOS: AccountInbox)
 */

/** Why an item is in the inbox. The servers name more reasons than these; the rest are plain updates. */
export type InboxReason = "review" | "mention" | "assigned" | "ciFailed" | "ci" | "update";

export function inboxReason(item: Pick<AccountWorkItem, "reason" | "title">): InboxReason {
  switch (item.reason) {
    case "review_requested": case "approval_requested": case "approval_required": return "review";
    case "mention": case "team_mention": case "mentioned": case "directly_addressed": return "mention";
    case "assign": case "assigned": return "assigned";
    case "build_failed": return "ciFailed";
    // GitHub says only that a run finished; the title says how it ended
    case "ci_activity": return /fail/i.test(item.title) ? "ciFailed" : "ci";
    default: return "update";
  }
}

/** "Mentioned by Sam" when the server names who did it, "Mentioned" otherwise */
export function inboxReasonLabel(reason: InboxReason, actor = ""): string {
  switch (reason) {
    case "review": return t("Review requested");
    case "mention": return actor ? t("Mentioned by {0}", actor) : t("Mentioned");
    case "assigned": return t("Assigned");
    case "ciFailed": return t("CI failed");
    case "ci": return t("CI run");
    default: return t("Updated");
  }
}

/** "#57", or nothing for what has no number (a release, a run) */
export const workReference = (item: Pick<AccountWorkItem, "number">) => (item.number > 0 ? `#${item.number}` : "");

/** "desktop" of "sample-studio/desktop": a row has room for the name; the detail shows the whole path */
export const repositoryName = (path: string) => path.split("/").filter(Boolean).pop() ?? path;

const startOfDay = (ms: number) => { const d = new Date(ms); return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime(); };

/**
 * docs/design.md, Dates: "12m ago" and "2h ago" within 24 hours, then "Yesterday", then the day, with the year only
 * for another year. Times are in seconds.
 */
export function workWhen(updated: number, now: number, language: string): string {
  const minutes = Math.floor((now - updated) / 60);
  if (minutes < 1) return t("Just now");
  if (minutes < 60) return t("{0}m ago", minutes);
  if (minutes < 24 * 60) return t("{0}h ago", Math.floor(minutes / 60));
  if (Math.round((startOfDay(now * 1000) - startOfDay(updated * 1000)) / 86_400_000) === 1) return t("Yesterday");
  const date = new Date(updated * 1000), sameYear = date.getFullYear() === new Date(now * 1000).getFullYear();
  return new Intl.DateTimeFormat(language, { month: "short", day: "numeric", ...(sameYear ? {} : { year: "numeric" }) }).format(date);
}

/** The search covers the title, the repository, the number and, in the inbox, the reason */
export function workMatches(item: AccountWorkItem, search: string): boolean {
  const words = search.trim().toLowerCase();
  if (!words) return true;
  const why = item.reason ? inboxReasonLabel(inboxReason(item), item.actor) : "";
  return [item.title, item.repository, workReference(item), why].some((text) => text.toLowerCase().includes(words));
}

/**
 * The rows the list shows: the search and the unread filter applied, then newest or oldest first. Rows that changed
 * at the same time, or carry no time, keep the order the server gave them.
 */
export function visibleWork(items: AccountWorkItem[], search: string, unreadOnly: boolean, oldestFirst: boolean): AccountWorkItem[] {
  return items
    .filter((item) => (!unreadOnly || item.unread) && workMatches(item, search))
    .map((item, index) => ({ item, index, time: item.updated ?? -Infinity }))
    .sort((a, b) => (a.time === b.time ? a.index - b.index : oldestFirst ? a.time - b.time : b.time - a.time))
    .map(({ item }) => item);
}

/** The rows that changed today and the earlier ones, each in the order given. `now` is in seconds. */
export function workGroups(items: AccountWorkItem[], now: number): { today: AccountWorkItem[]; earlier: AccountWorkItem[] } {
  const day = startOfDay(now * 1000);
  const today = items.filter((item) => item.updated !== null && startOfDay(item.updated * 1000) === day);
  return { today, earlier: items.filter((item) => !today.includes(item)) };
}

/** Whether the item is a request or an issue of the open repository, which a page of the app can show */
export function isLocalWork(item: AccountWorkItem, target: { host: string; path: string } | null | undefined): boolean {
  return !!target && item.number > 0 && item.kind !== "other"
    && item.host.toLowerCase() === target.host.toLowerCase() && item.repository.toLowerCase() === target.path.toLowerCase();
}
