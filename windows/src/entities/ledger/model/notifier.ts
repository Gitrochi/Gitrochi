import { ipc } from "@/shared/api";
import { isWindows, settings } from "@/shared/config";
import { Observable } from "@/shared/lib";
import type { LedgerBackend } from "../api/backend";
import { badgeLabel, type LedgerNotice, ledgerNotices, type LedgerTarget } from "../lib/notices";
import { ledgerRefreshDue } from "../lib/refresh";
import { LEDGER_POLL_MS } from "./reader";
import { ledgerStore } from "./store";
import type { LedgerState } from "./types";

/** Where notifications and the overlay go; the app's own commands, replaced in the self-test */
export interface LedgerNotifierSink {
  notify(notice: LedgerNotice): Promise<void>;
  /** A square RGBA image, or null to remove the overlay */
  badge(rgba: number[] | null, size: number): Promise<void>;
}

const appSink: LedgerNotifierSink = {
  notify: (n) => ipc.ledgerNotify(n.title, n.body, { ...n.target }),
  badge: (rgba, size) => ipc.ledgerBadge(rgba, size),
};

const BADGE_SIZE = 32;

/** The overlay image: the count in white on the theme's red disc, or null without a count or a canvas */
export function badgeImage(total: number, size = BADGE_SIZE): number[] | null {
  const label = badgeLabel(total);
  if (!label || typeof document === "undefined") return null;
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = size;
  const g = canvas.getContext("2d");
  if (!g) return null;
  const red = getComputedStyle(document.documentElement).getPropertyValue("--red").trim() || "#d93025";
  g.fillStyle = red;
  g.beginPath();
  g.arc(size / 2, size / 2, size / 2, 0, Math.PI * 2);
  g.fill();
  g.fillStyle = "#ffffff";
  g.font = `600 ${Math.round(size * (label.length > 2 ? 0.42 : label.length > 1 ? 0.55 : 0.66))}px "Segoe UI", system-ui, sans-serif`;
  g.textAlign = "center";
  g.textBaseline = "middle";
  g.fillText(label, size / 2, size / 2 + size * 0.04);
  return Array.from(g.getImageData(0, 0, size, size).data);
}

/**
 * The Ledger's notifications and taskbar badge (docs/ledger/DESIGN.md §10.11), both switches in Settings › Ledger that
 * stay off until a person turns them on.
 * Polls `rev` like the page does, reads the state of every project when it moved, and tells the person what is new;
 * a click opens the Ledger at the item (`onOpen`). The badge is the overlay on the taskbar button with
 * `attention.total`. Started with the Ledger preview only. (macOS: the Dock badge and UserNotifications)
 */
export class LedgerNotifier extends Observable {
  private last: LedgerState | null = null;
  private rev = -1;
  private stateReadAt = 0;
  private shownTotal = -1;
  private timer: ReturnType<typeof setInterval> | null = null;
  private polling = false;
  private readonly openers = new Set<(target: LedgerTarget) => void>();

  constructor(
    private readonly backend: () => LedgerBackend = () => ledgerStore(null).backend,
    private readonly sink: LedgerNotifierSink = appSink,
  ) {
    super();
  }

  /** Notifications about what is new (off until a person turns them on) */
  get notifications(): boolean {
    return settings.get<boolean>("ledgerNotifications", false);
  }

  setNotifications(on: boolean) {
    settings.set("ledgerNotifications", on || undefined);
    this.emit();
  }

  /** The count on the taskbar button (off until a person turns it on) */
  get badge(): boolean {
    return settings.get<boolean>("ledgerBadge", false);
  }

  setBadge(on: boolean) {
    settings.set("ledgerBadge", on || undefined);
    this.emit();
    void this.showBadge(this.last?.attention.total ?? 0);
  }

  start() {
    if (this.timer) return;
    void this.poll();
    this.timer = setInterval(() => void this.poll(), LEDGER_POLL_MS);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  /** Reads the state when `rev` moved, then notifies and updates the badge; the first read only learns what exists */
  async poll() {
    if (this.polling) return;
    // with both switches off nothing is read; the first read after one is turned on only learns what exists
    if (!this.notifications && !this.badge) {
      this.last = null;
      this.rev = -1;
      return;
    }
    this.polling = true;
    try {
      const backend = this.backend();
      const { rev } = await backend.call("rev", {});
      if (rev === this.rev && !ledgerRefreshDue(this.last, this.stateReadAt, Date.now())) return;
      const state = await backend.call("state", {});
      this.rev = state.rev;
      this.stateReadAt = Date.now();
      const notices = ledgerNotices(this.last, state);
      this.last = state;
      if (this.notifications) {
        for (const notice of notices) {
          try {
            await this.sink.notify(notice);
          } catch {
            // one that could not be shown does not keep the others back
          }
        }
      }
      await this.showBadge(state.attention.total);
    } catch {
      // the ledger cannot be read now; the next poll tries again
    } finally {
      this.polling = false;
    }
  }

  private async showBadge(total: number) {
    if (!isWindows()) return;
    const shown = this.badge ? total : 0;
    if (shown === this.shownTotal) return;
    this.shownTotal = shown;
    try {
      await this.sink.badge(badgeImage(shown), BADGE_SIZE);
    } catch {
      // no overlay now; the next change tries again
      this.shownTotal = -1;
    }
  }

  /** Called when a person clicks a notification */
  onOpen(fn: (target: LedgerTarget) => void) {
    this.openers.add(fn);
    return () => {
      this.openers.delete(fn);
    };
  }

  open(target: LedgerTarget) {
    for (const fn of this.openers) fn(target);
  }
}

export const ledgerNotifier = new LedgerNotifier();
