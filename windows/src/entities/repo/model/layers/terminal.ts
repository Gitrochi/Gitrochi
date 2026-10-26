import { addTab, paneOf, panes, removeTab, selectTab, setRatio, shownIn, splitPane, TerminalSession, type TerminalSpec, type TermSplit } from "@/entities/terminal";
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
    else if (!this.terminals.length) this.newTerminal();
    else this.showTerminal = true;
    this.emit();
  }

  private makeTerminal(dir: string, spec: Partial<TerminalSpec>) {
    const s = new TerminalSession({ ...spec, directory: dir });
    s.subscribe(() => this.emit());
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
    const pane = paneOf(this.terminalLayout, s.id);
    this.terminals = this.terminals.filter((t) => t !== s);
    this.terminalLayout = this.terminalLayout && removeTab(this.terminalLayout, s.id);
    if (this.activeTerminalID === s.id) {
      // stay in the same pane if it still has tabs, otherwise move to the first pane
      const next = paneOf(this.terminalLayout, pane?.sessions.find((id) => id !== s.id) ?? null) ?? (this.terminalLayout && panes(this.terminalLayout)[0]);
      this.activeTerminalID = next?.selected ?? this.terminals[this.terminals.length - 1]?.id ?? null;
    }
    if (!this.terminals.length) this.showTerminal = false;
    this.emit();
  }

  closeAllTerminals() {
    for (const t of this.terminals) t.dispose();
    this.terminals = [];
    this.terminalLayout = null;
    this.activeTerminalID = null;
    this.showTerminal = false;
  }
}
