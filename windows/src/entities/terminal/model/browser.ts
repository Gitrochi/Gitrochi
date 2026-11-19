import { type BrowserEvent, type BrowserRect, ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Observable } from "@/shared/lib";
import { resolveAddress as resolve, searchEngineKey } from "../lib/browser-address";
import { previewKind, previewPage, textLimit } from "../lib/file-preview";

/** Searches go to the engine chosen in Settings › Tools */
const resolveAddress = (text: string) => resolve(text, settings.get<string>(searchEngineKey, "google"));

/** Pages served by the app for file previews (preview.rs) */
const isPreviewAddress = (url: string) => /^(gitrochi-preview:|https?:\/\/gitrochi-preview\.localhost\/)/i.test(url);

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
  /** The local file the tab previews, if any; the address bar shows its path */
  file: string | null = null;
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
      // leaving a preview for a web page (a link, back, the address bar) forgets the file
      if (!isPreviewAddress(e.value) && e.value !== "about:blank") this.file = null;
      if (this.title === t("New tab")) this.title = this.hostName();
    } else this.loading = e.value;
    this.emit();
  };

  private hostName() {
    if (this.file) return this.file.split(/[\\/]/).pop() ?? this.file;
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

  /** What the address bar shows */
  get address(): string {
    return this.file ?? this.url ?? "";
  }

  private go(target: string) {
    this.url = target;
    this.emit();
    if (this.created) void this.created.then(() => ipc.browserNavigate(this.id, target).catch(() => undefined));
  }

  /** Goes to what was typed in the address bar: a local file's path, an address, or a search */
  open(text: string) {
    const value = text.trim();
    if (/^([a-z]:[\\/]|\\\\|\/)/i.test(value) && !value.startsWith("//")) {
      void ipc.exists(value).then((found) => (found ? this.openFile(value) : this.go(resolveAddress(value)!)));
      return;
    }
    const target = resolveAddress(value);
    if (target) this.go(target);
  }

  /** Previews a local file: the webview shows media, PDF and HTML itself, text formats get a page of their own */
  async openFile(path: string) {
    this.file = path;
    this.title = path.split(/[\\/]/).pop() ?? path;
    this.emit();
    const kind = previewKind(path);
    let address: string;
    if (kind.kind === "native") address = await ipc.previewRegister({ path, mime: kind.mime });
    else {
      const head = await ipc.readHead(path, textLimit).catch(() => null);
      const words = { cut: t("Only the first 2 MB are shown."), empty: t("The file is empty."), size: (rows: number, columns: number) => t("{0} rows · {1} columns", rows, columns) };
      const html = head && !head.binary ? previewPage(this.title, head.text, kind, head.truncated, words) : previewPage(this.title, t("This file can't be shown as text."), { kind: "text" }, false, words);
      address = await ipc.previewRegister({ html });
    }
    if (this.file === path) this.go(address);
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
    // a preview page is built again from the file on disk
    if (this.file) void this.openFile(this.file);
    else this.whenOpen(() => ipc.browserReload(this.id));
  }
  focus() {
    this.whenOpen(() => ipc.browserFocus(this.id));
  }
  openExternally() {
    if (this.file) void ipc.reveal(this.file).catch(() => undefined);
    else if (this.url && /^https?:/i.test(this.url)) void ipc.openUrl(this.url).catch(() => undefined);
  }

  dispose() {
    this.closed = true;
    if (this.created) void this.created.then(() => ipc.browserClose(this.id).catch(() => undefined));
  }
}
