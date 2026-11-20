import { addTab, BrowserSession, isLocalHost, paneOf, panes, removeTab, selectTab, sessionsToRestore, setRatio, shownIn, splitPane, TerminalSession, type TerminalSpec, type TermSplit } from "@/entities/terminal";
import { ipc } from "@/shared/api";
import { samePath } from "@/shared/config";
import { RepoAI } from "./ai";

/** 아래 터미널 패널 — split into panes of tabs (terminalLayout) */
export abstract class RepoTerminal extends RepoAI {
  get activeTerminal(): TerminalSession | null {
    return this.terminals.find((t) => t.id === this.activeTerminalID) ?? this.terminals[this.terminals.length - 1] ?? null;
  }

  /** The tab a pane shows */
  shownTerminal(paneId: string): TerminalSession | null {
    const p = this.terminalLayout && panes(this.terminalLayout).find((x) => x.id === paneId);
    const id = p ? shownIn(p, this.activeTerminalID) : null;
    return this.terminals.find((t) => t.id === id) ?? null;
  }

  /** Ctrl+` : 터미널 패널 보이기/숨기기(처음이면 저장소 폴더에서 셸을 하나 연다) */
  toggleTerminal() {
    if (this.showTerminal) this.showTerminal = false;
    else if (!this.terminals.length && !this.browsers.length) this.newTerminal();
    else this.showTerminal = true;
    this.emit();
  }

  private makeTerminal(dir: string, spec: Partial<TerminalSpec>) {
    const s = new TerminalSession({ repository: this.path ?? undefined, ...spec, directory: dir });
    s.subscribe(() => this.emit());
    s.onOpenLink = (text, candidates) => void this.openTerminalLink(s, text, candidates);
    this.terminals = [...this.terminals, s];
    this.activeTerminalID = s.id;
    this.showTerminal = true;
    return s;
  }

  /** A new tab in the focused pane */
  newTerminal(path?: string, spec: Partial<TerminalSpec> = {}): TerminalSession {
    const focused = paneOf(this.terminalLayout, this.activeTerminalID)?.id ?? null;
    const s = this.makeTerminal(path ?? this.path ?? "", spec);
    this.terminalLayout = addTab(this.terminalLayout, focused, s.id);
    this.emit();
    return s;
  }

  /** Tabs of this repository's terminals that outlived an earlier run of the app (the terminal host kept them) */
  async restoreTerminals() {
    const path = this.path;
    if (!path) return;
    const sessions = await ipc.ptySessions().catch(() => []);
    if (this.path !== path) return;
    const shown = new Set(this.terminals.map((t) => t.hostSession).filter((id): id is string => !!id));
    for (const { session, meta } of sessionsToRestore(sessions, path, shown, samePath)) {
      this.newTerminal(meta.spec.directory, { ...meta.spec, repository: meta.repository, resume: session.id });
    }
  }

  /** A new shell beside (row) or below (column) the pane, in the folder its terminal is in */
  splitTerminal(paneId: string, axis: TermSplit["axis"]) {
    const layout = this.terminalLayout;
    if (!layout || !panes(layout).some((p) => p.id === paneId)) return this.newTerminal();
    const s = this.makeTerminal(this.shownTerminal(paneId)?.directory ?? this.path ?? "", {});
    this.terminalLayout = splitPane(layout, paneId, axis, s.id);
    this.emit();
    return s;
  }

  resizeTerminalSplit(splitId: string, ratio: number) {
    if (!this.terminalLayout) return;
    this.terminalLayout = setRatio(this.terminalLayout, splitId, ratio);
    this.emit();
  }

  selectTerminal(s: TerminalSession) {
    this.activeTerminalID = s.id;
    if (this.terminalLayout) this.terminalLayout = selectTab(this.terminalLayout, s.id);
    s.unseenOutput = false;
    this.emit();
  }

  focusTerminal(s: TerminalSession) {
    this.activateTab?.();
    this.showTerminal = true;
    this.selectTerminal(s);
    setTimeout(() => s.focus(), 50);
  }

  closeTerminal(s: TerminalSession) {
    s.dispose();
    this.terminals = this.terminals.filter((t) => t !== s);
    this.removePaneTab(s.id);
  }

  /** Takes a closed terminal or browser tab out of its pane */
  private removePaneTab(id: string) {
    const pane = paneOf(this.terminalLayout, id);
    this.terminalLayout = this.terminalLayout && removeTab(this.terminalLayout, id);
    if (this.activeTerminalID === id) {
      // stay in the same pane if it still has tabs, otherwise move to the first pane
      const next = paneOf(this.terminalLayout, pane?.sessions.find((x) => x !== id) ?? null) ?? (this.terminalLayout && panes(this.terminalLayout)[0]);
      this.activeTerminalID = next?.selected ?? this.terminals[this.terminals.length - 1]?.id ?? null;
    }
    if (!this.terminals.length && !this.browsers.length) this.showTerminal = false;
    this.emit();
  }

  // Browser tabs share the panes: the layout holds their ids next to the terminals'. macOS: RepoStore+Browser.swift

  browser(id: string | null): BrowserSession | null {
    return this.browsers.find((b) => b.id === id) ?? null;
  }

  /** The browser tab a pane shows, when it shows one */
  shownBrowser(paneId: string): BrowserSession | null {
    const p = this.terminalLayout && panes(this.terminalLayout).find((x) => x.id === paneId);
    return this.browser(p ? shownIn(p, this.activeTerminalID) : null);
  }

  /** A new browser tab in the focused pane, or beside the pane when one is given */
  newBrowser(url: string | null = null, besidePane?: string): BrowserSession {
    const b = new BrowserSession(url);
    b.subscribe(() => this.emit());
    this.browsers = [...this.browsers, b];
    const layout = this.terminalLayout;
    if (besidePane && layout && panes(layout).some((p) => p.id === besidePane)) this.terminalLayout = splitPane(layout, besidePane, "row", b.id);
    else this.terminalLayout = addTab(layout, paneOf(layout, this.activeTerminalID)?.id ?? null, b.id);
    this.activeTerminalID = b.id;
    this.showTerminal = true;
    this.emit();
    return b;
  }

  /** The latest browser tab still in a pane, or a new one beside the terminal's pane */
  private browserFor(beside: string): BrowserSession {
    const b = [...this.browsers].reverse().find((x) => paneOf(this.terminalLayout, x.id));
    return b ?? this.newBrowser(null, paneOf(this.terminalLayout, beside)?.id);
  }

  /** A web address from a terminal: dev servers open in a browser tab, other sites in the system browser */
  openInBrowserTab(url: string, beside: string) {
    const b = this.browserFor(beside);
    b.open(url);
    this.showTerminal = true;
    this.selectBrowser(b);
  }

  /** A file Ctrl-clicked in a terminal: previewed in the latest browser tab, or a new one beside the terminal */
  previewInBrowserTab(path: string, beside: string) {
    const b = this.browserFor(beside);
    void b.openFile(path);
    this.showTerminal = true;
    this.selectBrowser(b);
  }

  /** What a Ctrl-click on a word in the terminal does (macOS: onOpenLink in TerminalSession.swift) */
  async openTerminalLink(s: TerminalSession, text: string, candidates = [text]) {
    if (/^https?:\/\//i.test(text)) {
      let host = "";
      try {
        host = new URL(text).host;
      } catch {
        return;
      }
      if (isLocalHost(host)) this.openInBrowserTab(text, s.id);
      else void ipc.openUrl(text).catch(() => undefined);
      return;
    }
    // a path with spaces: the longest candidate that exists
    for (const candidate of candidates) {
      const path = await ipc.previewResolve(candidate, s.directory).catch(() => null);
      if (path) return this.previewInBrowserTab(path, s.id);
    }
  }

  selectBrowser(b: BrowserSession) {
    this.activeTerminalID = b.id;
    if (this.terminalLayout) this.terminalLayout = selectTab(this.terminalLayout, b.id);
    this.emit();
  }

  closeBrowser(b: BrowserSession) {
    b.dispose();
    this.browsers = this.browsers.filter((x) => x !== b);
    this.removePaneTab(b.id);
  }

  closeAllTerminals() {
    for (const t of this.terminals) t.dispose();
    for (const b of this.browsers) b.dispose();
    this.browsers = [];
    this.terminals = [];
    this.terminalLayout = null;
    this.activeTerminalID = null;
    this.showTerminal = false;
  }
}
