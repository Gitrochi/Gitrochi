import { ChevronDown, Columns2, ExternalLink, Plus, Rows2, SquareTerminal, X } from "lucide-react";
import { useEffect, useLayoutEffect, useRef } from "react";
import type { RepoStore } from "@/entities/repo";
import { cornerPane, panes, type TerminalSession, type TermNode, type TermPane, type TermSplit } from "@/entities/terminal";
import { ipc } from "@/shared/api";
import { displayPath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, IconButton, tip } from "@/shared/ui";
import "./terminal-panel.css";

/** 가운데 열 아래의 터미널 패널. 경계선을 끌어 높이를 바꾼다. Panes can be split right or down, each with its own tabs. */
export function TerminalPanel({ store, columnHeight }: { store: RepoStore; columnHeight: number }) {
  useObserve(store);
  useObserve(settings);
  const max = Math.max(120, columnHeight - 200);
  const height = Math.min(Math.max(settings.get("terminalHeight", 260), 120), max);
  const layout = store.terminalLayout;

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
  const tabs = pane.sessions.map((id) => store.terminals.find((x) => x.id === id)).filter((x): x is TerminalSession => !!x);
  return (
    <div className={`term-pane ${split && focused ? "focused" : ""}`}>
      <div className="term-head">
        <SquareTerminal size={14} className="muted" />
        <div className="term-tabs">
          {tabs.map((term) => (
            <TermTab key={term.id} term={term} n={store.terminals.length > 1 ? store.terminals.indexOf(term) + 1 : null} on={term === s} store={store} />
          ))}
        </div>
        <IconButton
          small
          icon={<Plus size={14} />}
          tip={tip(t("New terminal"), t("Opens another shell in the repository folder."), "Ctrl+Shift+`")}
          onClick={() => {
            if (s) store.selectTerminal(s);
            store.newTerminal();
          }}
        />
        <IconButton small icon={<Columns2 size={13} />} tip={tip(t("Split right"), t("Opens another shell next to this one, in the same folder."))} onClick={() => store.splitTerminal(pane.id, "row")} />
        <IconButton small icon={<Rows2 size={13} />} tip={tip(t("Split down"), t("Opens another shell below this one, in the same folder."))} onClick={() => store.splitTerminal(pane.id, "column")} />
        <span className="spacer" />
        {pane.id === corner && s && (
          <IconButton
            small
            icon={<ExternalLink size={13} />}
            tip={tip(t("Open in external terminal"), t("Opens the current folder ({0}) in a new Windows Terminal window.", displayPath(s.directory)))}
            onClick={() => void ipc.openTerminal(s.directory)}
          />
        )}
        {pane.id === corner && (
          <IconButton
            small
            icon={<ChevronDown size={15} />}
            tip={tip(t("Hide terminal"), t("Only the panel is hidden; shells keep running."), "Ctrl+`")}
            onClick={() => {
              store.showTerminal = false;
              store.changed();
            }}
          />
        )}
      </div>
      <div className="term-body" onMouseDownCapture={() => s && !focused && store.selectTerminal(s)}>
        {s && <TerminalMount key={s.id} session={s} height={height} store={store} focus={focused} />}
      </div>
    </div>
  );
}

function TermTab({ term, n, on, store }: { term: TerminalSession; n: number | null; on: boolean; store: RepoStore }) {
  useObserve(term);
  const color = term.running ? (term.unseenOutput ? "var(--accent)" : "var(--green)") : "var(--text-3)";
  return (
    <div className={`term-tab ${on ? "on" : ""}`} onClick={() => store.selectTerminal(term)} data-tip={displayPath(term.directory)}>
      <span className="dot" style={{ width: 6, height: 6, background: color }} />
      {n !== null && <span className="muted">{n}</span>}
      <span className="ellipsis" style={{ maxWidth: 150 }}>
        {term.title}
      </span>
      <IconButton
        small
        className="x"
        icon={<X size={11} />}
        tip={t("Close terminal")}
        onClick={(e) => {
          e.stopPropagation();
          if (term.running && term.spec.program)
            store.ask({ title: t("Close the terminal?"), message: t("'{0}' is still running. Closing it will stop it.", term.title), actionTitle: t("Close"), action: () => store.closeTerminal(term) });
          else store.closeTerminal(term);
        }}
      />
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
