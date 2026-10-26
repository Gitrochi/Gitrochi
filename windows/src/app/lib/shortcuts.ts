import { workspace } from "@/entities/workspace";
import { isMac, settings } from "@/shared/config";

/** 앱 단축키(Windows: Ctrl, 맥: ⌘). 터미널에 포커스가 있으면 터미널이 넘겨준 조합만 온다. */
export function handleShortcut(e: KeyboardEvent, openSettings: () => void) {
  if (e.defaultPrevented) return;
  if (document.querySelector(".modal-backdrop")) return; // 대화상자가 떠 있으면 대화상자가 처리
  const s = workspace.active;
  if (!s) return;
  const k = e.key.toLowerCase();
  const mod = isMac() ? e.metaKey : e.ctrlKey;
  const target = e.target as HTMLElement | null;
  const inText = !!target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.tagName === "SELECT") && !target.closest(".xterm");
  const run = (f: () => unknown) => {
    e.preventDefault();
    e.stopPropagation();
    void f();
  };

  if (e.ctrlKey && e.code === "Backquote") return run(() => (s.path ? (e.shiftKey ? s.newTerminal() : s.toggleTerminal()) : undefined));
  if (e.ctrlKey && e.key === "Tab") return run(() => workspace.selectRelative(e.shiftKey ? -1 : 1));
  if (e.key === "F5" || (mod && !e.shiftKey && !e.altKey && k === "r")) return run(() => s.reload());
  if (e.key === "F3") return run(() => (e.shiftKey ? s.previousMatch() : s.nextMatch()));
  if (!mod) return;
  if (inText && !e.shiftKey && !e.altKey && ["a", "c", "v", "x", "z", "y"].includes(k)) return;

  if (!e.shiftKey && !e.altKey) {
    switch (k) {
      case "t":
        return run(() => workspace.newTab());
      case "w":
        return run(() => workspace.closeTab(s.id));
      case "o":
        return run(() => (s.path ? workspace.newTab() : s).pickAndOpen());
      case "f":
        return run(() => s.path && s.requestSearchFocus());
      case "b":
        // the page list folds into a rail of icons and back
        return run(() => settings.set("navigationSidebarCollapsed", !settings.get("navigationSidebarCollapsed", false)));
      case "g":
        return run(() => s.nextMatch());
      // the pages, numbered as in the macOS View menu
      case "0":
        return run(() => s.navigate("home"));
      case "1":
        return run(() => { if (s.navigate("repository")) s.select({ kind: "wip" }); });
      case "2":
        return run(() => { if (s.navigate("repository") && s.headHash) s.select({ kind: "commit", sha: s.headHash }); });
      case "3":
        return run(() => s.navigate("compare"));
      case "4":
        return run(() => s.navigate("pullRequests"));
      case "5":
        return run(() => s.navigate("actions"));
      case "6":
        return run(() => s.navigate("flows"));
      case "z":
        // 입력 칸 밖에서만(입력 칸에서는 글자 되돌리기 — 위에서 걸러 짐)
        return run(() => s.path && s.confirmUndo());
      case ",":
        return run(openSettings);
    }
  }
  if (e.shiftKey && !e.altKey && s.path) {
    switch (k) {
      case "g":
        return run(() => s.previousMatch());
      case "o":
        return run(() => s.openSheet({ kind: "clone" }));
      case "f":
        return run(() => s.fetch());
      case "l":
        return run(() => s.pull());
      case "p":
        return run(() => s.push());
      case "b":
        return run(() => s.requestNewBranch());
      case "s":
        return run(() => s.openSheet({ kind: "stash" }));
    }
  }
  if (e.shiftKey && !e.altKey && !s.path && k === "o") return run(() => s.openSheet({ kind: "clone" }));
  if (e.altKey && !e.shiftKey && s.path) {
    switch (k) {
      case "w":
        return run(() => s.openSheet({ kind: "addWorktree", branch: null, start: null }));
      case "m":
        return run(() => s.generateCommitMessage());
      case "k":
        return run(() => s.openSheet({ kind: "startAgent", path: s.path }));
    }
  }
}
