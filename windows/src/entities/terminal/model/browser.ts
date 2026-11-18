import { type BrowserEvent, type BrowserRect, ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { Observable } from "@/shared/lib";
import { resolveAddress } from "../lib/browser-address";

const sameRect = (a: BrowserRect | null, b: BrowserRect | null) =>
  a === b || (!!a && !!b && a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height);

/**
 * A browser tab in a terminal pane. The page is a native child webview that the pane keeps over its own box, so it
 * lives on while the tab is hidden, like a terminal's shell. macOS: Services/BrowserSession.swift
 */
export class BrowserSession extends Observable {
  readonly id = crypto.randomUUID();
  title: string;
  url: string | null;
  loading = false;
  /** The page's own history is not visible from here, so back and forward stay available */
  private created: Promise<void> | null = null;
  private shownRect: BrowserRect | null = null;
  private closed = false;

  constructor(url: string | null = null) {
    super();
    this.url = url;
    this.title = t("New tab");
  }

  private onEvent = (e: BrowserEvent) => {
    if (e.kind === "title") this.title = e.value.trim() || this.hostName();
    else if (e.kind === "url") {
      this.url = e.value;
      if (this.title === t("New tab")) this.title = this.hostName();
    } else this.loading = e.value;
    this.emit();
  };

  private hostName() {
    try {
      return this.url ? new URL(this.url).host || t("New tab") : t("New tab");
    } catch {
      return t("New tab");
    }
  }

  /** Puts the page over the pane's box, or hides it (null). The webview is made the first time it has a place. */
  place(rect: BrowserRect | null) {
    if (this.closed || sameRect(rect, this.shownRect)) return;
    this.shownRect = rect;
    if (!this.created) {
      if (!rect) return;
      this.created = ipc.browserOpen(this.id, this.url ?? "about:blank", rect, this.onEvent).catch(() => {
        this.created = null;
        this.shownRect = null;
      });
      return;
    }
    void this.created.then(() => (this.closed ? undefined : ipc.browserPlace(this.id, rect ?? { x: 0, y: 0, width: 1, height: 1 }, !!rect).catch(() => undefined)));
  }

  /** Goes to what was typed in the address bar */
  open(text: string) {
    const target = resolveAddress(text);
    if (!target) return;
    this.url = target;
    this.emit();
    if (this.created) void this.created.then(() => ipc.browserNavigate(this.id, target).catch(() => undefined));
  }

  private whenOpen(f: () => Promise<void>) {
    if (this.created) void this.created.then(() => f().catch(() => undefined));
  }

  back() {
    this.whenOpen(() => ipc.browserHistory(this.id, -1));
  }
  forward() {
    this.whenOpen(() => ipc.browserHistory(this.id, 1));
  }
  reload() {
    this.whenOpen(() => ipc.browserReload(this.id));
  }
  focus() {
    this.whenOpen(() => ipc.browserFocus(this.id));
  }
  openExternally() {
    if (this.url && /^https?:/i.test(this.url)) void ipc.openUrl(this.url).catch(() => undefined);
  }

  dispose() {
    this.closed = true;
    if (this.created) void this.created.then(() => ipc.browserClose(this.id).catch(() => undefined));
  }
}
