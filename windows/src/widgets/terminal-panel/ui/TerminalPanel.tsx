import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { RepoStore } from "@/entities/repo";
import { commandHintShown, commandsFolded, cornerPane, panes, railShown, statusLine, type TerminalSession, type TermNode, type TermPane, type TermSplit } from "@/entities/terminal";
import { ipc } from "@/shared/api";
import { samePath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button } from "@/shared/ui";
import { TerminalQuickActions, TerminalStatusBar } from "./TerminalChrome";
import { tabStatus, TerminalTabBar } from "./TerminalTabBar";
import "./terminal-panel.css";

/** How often the shells are asked whether a command runs in them (the tab's ring) */
const activityInterval = 2000;

/**
 * 가운데 열 아래의 터미널 패널. 경계선을 끌어 높이를 바꾼다. Panes can be split right or down, each with its own tabs.
 * It docks under the centre column only: the sidebar and the right panel keep the full window height (docs/design.md › App shell).
 */
export function TerminalPanel({ store, columnHeight }: { store: RepoStore; columnHeight: number }) {
  useObserve(store);
  useObserve(settings);
  const max = Math.max(120, columnHeight - 200);
  const height = Math.min(Math.max(settings.get("terminalHeight", 260), 120), max);
  const layout = store.terminalLayout;
  // A shell does not say when a command starts or ends, so ask for the processes below it while the panel shows
  useEffect(() => {
    let stopped = false;
    const check = async () => {
      const shells = store.terminals.filter((x) => x.running && !x.spec.program && x.pid !== null);
      if (!shells.length || document.hidden) return;
      const pids = shells.map((x) => x.pid!);
      try {
        const counts = await ipc.processDescendants(pids);
        if (!stopped) shells.forEach((x, i) => x.running && x.pid === pids[i] && x.noteChildren(counts[i] ?? 0));
      } catch {
        // without the process table the tabs only lose their running mark
      }
    };
    void check();
    const timer = setInterval(() => void check(), activityInterval);
    return () => {
      stopped = true;
      clearInterval(timer);
    };
  }, [store]);

  const startDrag = (e: React.MouseEvent) => {
    e.preventDefault();
    const y0 = e.clientY,
      h0 = height;
    const move = (ev: MouseEvent) => settings.set("terminalHeight", Math.min(Math.max(h0 - (ev.clientY - y0), 120), max));
    const up = () => {
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
      document.body.style.cursor = "";
    };
    document.body.style.cursor = "row-resize";
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
  };

  return (
    <>
      <div className="hsplitter" onMouseDown={startDrag} />
      <div className="term-panel" style={{ height }}>
        {layout && <TermNodeView node={layout} corner={cornerPane(layout).id} split={panes(layout).length > 1} store={store} height={height} />}
      </div>
    </>
  );
}

type NodeProps = { corner: string; split: boolean; store: RepoStore; height: number };

function TermNodeView({ node, ...p }: NodeProps & { node: TermNode }) {
  return node.kind === "pane" ? <TermPaneView pane={node} {...p} /> : <TermSplitView node={node} {...p} />;
}

function TermSplitView({ node, ...p }: NodeProps & { node: TermSplit }) {
  const ref = useRef<HTMLDivElement>(null);
  const row = node.axis === "row";
  const startDrag = (e: React.MouseEvent) => {
    e.preventDefault();
    const box = ref.current!.getBoundingClientRect();
    const move = (ev: MouseEvent) => p.store.resizeTerminalSplit(node.id, row ? (ev.clientX - box.left) / box.width : (ev.clientY - box.top) / box.height);
    const up = () => {
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
      document.body.style.cursor = "";
    };
    document.body.style.cursor = row ? "col-resize" : "row-resize";
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
  };
  return (
    <div ref={ref} className={`term-split ${row ? "side-by-side" : "stacked"}`}>
      <div className="term-split-part" style={{ flex: `${node.ratio} 1 0` }}>
        <TermNodeView node={node.a} {...p} />
      </div>
      <div className="term-divider" onMouseDown={startDrag} />
      <div className="term-split-part" style={{ flex: `${1 - node.ratio} 1 0` }}>
        <TermNodeView node={node.b} {...p} />
      </div>
    </div>
  );
}

function TermPaneView({ pane, corner, split, store, height }: NodeProps & { pane: TermPane }) {
  const s = store.shownTerminal(pane.id);
  const focused = !!s && s === store.activeTerminal;
  // the bar, the rail and the status line fold by the pane's own size, so a split pane folds before the panel does
  const ref = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ width: 800, height: 260 });
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => setSize((old) => (old.width === el.clientWidth && old.height === el.clientHeight ? old : { width: el.clientWidth, height: el.clientHeight }));
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const status = s ? tabStatus(s) : null;
  const parts = statusLine(size.width);
  const insert = (command: string) => {
    if (!s || !s.running) return;
    store.selectTerminal(s);
    // pasted, not sent: the line waits at the prompt until the user presses Enter
    s.term.paste(command);
    s.focus();
  };
  return (
    <div ref={ref} className={`term-pane ${split && !focused ? "unfocused" : ""}`}>
      <TerminalTabBar pane={pane} shown={s} corner={pane.id === corner} width={size.width} store={store} />
      <div className="term-body" onMouseDownCapture={() => s && !focused && store.selectTerminal(s)}>
        {s && <TerminalMount key={s.id} session={s} height={height} store={store} focus={focused} />}
      </div>
      {s && railShown(size.height) && <TerminalQuickActions folded={commandsFolded(size.width)} hint={commandHintShown(size.width)} enabled={s.running} insert={insert} />}
      {s && status && (
        <TerminalStatusBar
          directory={s.directory}
          state={status.activity}
          program={parts.shell ? s.program : null}
          branch={parts.branch && samePath(s.directory, store.path) ? store.headBranch : null}
          unseen={store.terminals.filter((x) => x.unseenOutput).length}
          nextUnseen={() => {
            const next = store.terminals.find((x) => x.unseenOutput);
            if (next) store.selectTerminal(next);
          }}
        />
      )}
    </div>
  );
}

/** 세션의 xterm 화면을 붙인다. 화면은 세션이 들고 있어 탭을 바꿔도 내용과 셸이 그대로다. */
function TerminalMount({ session, height, store, focus }: { session: TerminalSession; height: number; store: RepoStore; focus: boolean }) {
  useObserve(session);
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    session.attach(el);
    const ro = new ResizeObserver(() => session.refit());
    ro.observe(el);
    // with several panes only the focused one takes the keyboard
    const timer = setTimeout(() => focus && session.focus(), 30);
    return () => {
      clearTimeout(timer);
      ro.disconnect();
      session.detach();
    };
  }, [session]);
  useEffect(() => {
    session.refit();
  }, [height, session]);
  return (
    <>
      <div className="term-mount" ref={ref} />
      {!session.running && session.started && (
        <div className="term-ended">
          <div className="box">
            <span className="muted">{session.exitCode !== null ? t("The process exited (code {0})", session.exitCode) : t("The process exited")}</span>
            <div className="row">
              <Button kind="primary" onClick={() => void session.start().then(() => session.focus())}>
                {t("Restart")}</Button>
              <Button onClick={() => store.closeTerminal(session)}>{t("Close")}</Button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
