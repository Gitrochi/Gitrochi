import type { LedgerStore, LedgerTarget } from "@/entities/ledger";
import type { RepoStore } from "@/entities/repo";
import { workspace } from "@/entities/workspace";
import { ipc } from "@/shared/api";
import { env } from "@/shared/config";

/** Opens the Ledger at a notification's item: the page, the session in the inspector, the Inbox for a prompt */
export function openLedgerAt(tab: RepoStore, store: LedgerStore, target: LedgerTarget) {
  tab.navigate("ledger");
  if (target.promptId !== undefined || !target.sessionId) store.setView("inbox");
  if (target.sessionId) store.select(target.sessionId);
}

/**
 * The Ledger's notifications and taskbar badge (docs/ledger/DESIGN.md §10.11), with the Ledger preview only and loaded
 * on demand like the page. A click on a notification brings the window forward (Rust) and opens the item in the active tab.
 */
export async function startLedgerNotifications() {
  if (!env.ledgerPreview) return;
  const { ledgerNotifier, ledgerStore } = await import("@/entities/ledger");
  ledgerNotifier.onOpen((target) => {
    const tab = workspace.active;
    if (tab) openLedgerAt(tab, ledgerStore(tab.path), target);
  });
  await ipc.onLedgerNotification((target) => ledgerNotifier.open(target ?? {}));
  ledgerNotifier.start();
}
