import { compareVersions, type LedgerSession, type LedgerStore } from "@/entities/ledger";
import { t } from "@/shared/i18n";
import { type MenuItem, showMenuBelow } from "@/shared/ui";

const HOUR = 3_600_000;

/** The project's baselines to merge into, newest first, the newest one marked */
function mergeItems(store: LedgerStore, session: LedgerSession): MenuItem[] {
  const versions = (store.state?.baselines ?? []).filter((b) => b.project === session.project).map((b) => b.version).sort(compareVersions).reverse();
  const items: MenuItem[] = versions.slice(0, 12).map((version, i) => ({ label: i === 0 ? t("{0} (newest)", version) : version, checked: version === session.mergedInto, onClick: () => void store.human({ action: "set_status", sessionId: session.id, status: "merged", into: version }) }));
  return items.length ? items : [{ label: t("No baselines yet"), disabled: true }];
}

/** "Mark merged…": which baseline the result went into */
export function mergeMenu(anchor: HTMLElement, store: LedgerStore, session: LedgerSession) {
  showMenuBelow(anchor, mergeItems(store, session));
}

/** The operations a session offers in its "More" menu; drop asks first through `confirmDrop` */
export function moreMenu(store: LedgerStore, s: LedgerSession, confirmDrop: () => void): MenuItem[] {
  const human = (action: Parameters<LedgerStore["human"]>[0]["action"], extra: Omit<Parameters<LedgerStore["human"]>[0], "action" | "sessionId"> = {}) => () => void store.human({ action, sessionId: s.id, ...extra });
  const finished = s.status === "merged" || s.status === "closed" || s.status === "dropped";
  const items: MenuItem[] = [
    { label: t("Mark merged"), submenu: mergeItems(store, s) },
    { label: t("Mark done"), onClick: human("set_status", { status: "done" }), disabled: s.status === "done" },
    { label: t("Mark closed"), onClick: human("set_status", { status: "closed" }), disabled: s.status === "closed" },
    { label: t("Mark dropped…"), onClick: confirmDrop, danger: true, disabled: s.status === "dropped" },
    "divider",
    { label: t("Shelve"), onClick: human("shelve"), disabled: s.status === "shelved", tip: `${t("Shelve")}|${t("Paused research or documents, kept for later. Never turns stale.")}` },
    { label: t("Still active"), onClick: human("snooze", { until: Date.now() + 72 * HOUR }), disabled: finished || s.status === "shelved" },
    { label: t("Make active again"), onClick: human("set_status", { status: "active" }), disabled: s.status === "active" && !s.archivedAt },
    "divider",
    s.ackAt ? { label: t("Take back confirmation"), onClick: human("unack") } : { label: t("Confirm"), onClick: human("ack"), disabled: !finished },
    s.archivedAt ? { label: t("Restore"), onClick: human("unarchive") } : { label: t("Clean up"), onClick: human("archive") },
  ];
  return items;
}
