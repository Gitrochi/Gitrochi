import { ChevronLeft, Clock, FileArchive, FolderOpen, History, ScanText, TriangleAlert } from "lucide-react";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { avatars } from "@/entities/avatar";
import { type BlameLine, isUncommittedLine, short } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { longDate, shortDate, useObserve } from "@/shared/lib";
import { Avatar, Button, Empty, IconButton, Segmented, Spinner, tip } from "@/shared/ui";
import { DiffBody, DiffEmptyState } from "./DiffView";
import "./diff-viewer.css";

const BLAME_H = 18;

/** 파일 히스토리 · 줄별 작성자(blame). 그래프 자리를 대신 차지하고, Esc 로 돌아간다. (맥 버전 FileInspectView) */
export function FileInspectView({ store }: { store: RepoStore }) {
  useObserve(store);
  useObserve(avatars);
  const f = store.fileInspect!;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !document.querySelector(".modal-backdrop") && !(e.target as HTMLElement)?.closest?.(".xterm")) store.closeFileInspect();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [store]);
  const subtitle = f.mode === "history" ? t("{0} · {1} commits", f.path, store.fileHistory.length) : `${f.path} · ${f.rev ? t("As of commit {0}", short(f.rev)) : t("As of the working tree")}`;

  return (
    <div className="col grow" style={{ minHeight: 0 }}>
      <div className="diff-head">
        <Button size="small" onClick={() => store.closeFileInspect()} tip={t("Back to graph (Esc)")}>
          <ChevronLeft size={14} /> {" "}{t("Graph")}</Button>
        <span className="muted" style={{ display: "inline-flex" }}>
          {f.mode === "history" ? <History size={16} /> : <ScanText size={16} />}
        </span>
        <div className="col grow">
          <span className="ellipsis" style={{ fontWeight: 600 }}>
            {f.path.split("/").pop()}
          </span>
          <span className="ellipsis muted" style={{ fontSize: 11.5 }}>
            {subtitle}
          </span>
        </div>
        <Button size="small" onClick={() => store.openLineHistory(f.path, f.rev ?? undefined, store.fileInspectLine ?? 1)}>{t("Trace lines…")}</Button>
        {store.fileInspectLoading && <Spinner size={13} />}
        <IconButton icon={<FolderOpen size={15} />} aria-label={t("Show in Explorer")} tip={t("Show in Explorer")} onClick={() => void store.revealPath(f.path)} />
        <Segmented
          value={f.mode}
          onChange={(m) => store.setFileInspectMode(m)}
          options={[
            { value: "history", label: t("History"), tip: t("Commits that changed this file") },
            { value: "blame", label: t("Blame"), tip: t("Who changed each line and when") },
          ]}
        />
      </div>
      {store.fileInspectError ? (
        <Empty icon={<TriangleAlert size={30} />} title={t("Couldn't read")} detail={store.fileInspectError} />
      ) : f.mode === "history" ? (
        <HistoryPane store={store} />
      ) : (
        <BlamePane store={store} />
      )}
    </div>
  );
}

/** 위: 이 파일을 바꾼 커밋들, 아래: 고른 커밋에서의 변경 */
function HistoryPane({ store }: { store: RepoStore }) {
  const doc = store.fileHistoryDiff;
  const listH = Math.min(8, Math.max(2, store.fileHistory.length)) * 40 + 4;
  return (
    <div className="col grow" style={{ minHeight: 0 }}>
      <div className="history-list" style={{ height: listH }}>
        {store.fileHistory.map((e) => (
          <div
            key={e.commit.id}
            className={`history-row ${store.fileHistorySelected === e.commit.id ? "on" : ""}`}
            onClick={() => void store.selectHistory(e)}
            onDoubleClick={() => {
              store.closeFileInspect();
              store.reveal(e.commit.id);
            }}
            data-tip={tip(e.commit.subject, t("{0} · {1}\nDouble-click: show this commit in the graph", e.commit.author, longDate(e.commit.date)))}
          >
            <Avatar name={e.commit.author} email={e.commit.email} size={20} url={avatars.url(e.commit.email, e.commit.author)} />
            <div className="col grow" style={{ minWidth: 0 }}>
              <span className="ellipsis">{e.commit.subject}</span>
              <span className="side-sub row" style={{ gap: 6 }}>
                <span>{e.commit.author}</span>
                <span>{shortDate(e.commit.date)}</span>
                {e.path !== store.fileInspect?.path && <span style={{ color: "var(--orange)" }}>{t("Previous name: {0}", e.path)}</span>}
              </span>
            </div>
            <span className="mono muted" style={{ fontSize: 11.5 }}>
              {short(e.commit.id)}
            </span>
          </div>
        ))}
      </div>
      {!doc ? (
        store.fileHistory.length ? (
          <div className="empty">
            <Spinner size={20} />
          </div>
        ) : store.fileInspectLoading ? null : (
          <Empty icon={<Clock size={30} />} title={t("No history")} detail={t("This file hasn't been committed yet.")} />
        )
      ) : doc.error ? (
        <Empty icon={<TriangleAlert size={30} />} title={t("Couldn't read the changes")} detail={doc.error} />
      ) : doc.isBinary ? (
        <Empty icon={<FileArchive size={30} />} title={t("Binary file")} />
      ) : !doc.lines.length ? (
        <DiffEmptyState doc={doc} />
      ) : (
        <DiffBody store={store} doc={doc} split={store.diffSplit} editable={false} staged={false} />
      )}
    </div>
  );
}

/** 줄마다 마지막으로 바꾼 커밋. 같은 커밋이 이어지면 첫 줄에만 작성자·날짜, 오래된 줄일수록 옅은 띠. */
function BlamePane({ store }: { store: RepoStore }) {
  const lines = store.blameLines;
  const [oldest, newest] = useMemo(() => {
    const ds = lines.filter((l) => !isUncommittedLine(l)).map((l) => l.date);
    return ds.length ? [Math.min(...ds), Math.max(...ds)] : [0, 0];
  }, [lines]);
  const ref = useRef<HTMLDivElement>(null);
  const [vp, setVp] = useState({ top: 0, height: 800 });
  const targetLine = store.fileInspectLine;
  useLayoutEffect(() => {
    if (!targetLine || store.fileInspectLoading || !ref.current || !lines.some((l) => l.no === targetLine)) return;
    ref.current.scrollTop = Math.max(0, (targetLine - 1) * BLAME_H - ref.current.clientHeight / 2 + BLAME_H / 2);
  }, [targetLine, lines, store.fileInspectLoading]);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const update = () => setVp({ top: el.scrollTop, height: el.clientHeight });
    update();
    const ro = new ResizeObserver(update);
    ro.observe(el);
    el.addEventListener("scroll", update, { passive: true });
    return () => {
      ro.disconnect();
      el.removeEventListener("scroll", update);
    };
  }, []);
  if (!lines.length && !store.fileInspectLoading) return <Empty icon={<ScanText size={30} />} title={t("No content")} detail={t("The file is empty or not committed yet.")} />;
  const first = Math.max(0, Math.floor(vp.top / BLAME_H) - 20);
  const last = Math.min(lines.length, Math.ceil((vp.top + vp.height) / BLAME_H) + 20);
  const age = (l: BlameLine) => {
    if (isUncommittedLine(l)) return "color-mix(in srgb, var(--orange) 12%, transparent)";
    const secs = newest > oldest ? (l.date - oldest) / (newest - oldest) : 1;
    return `color-mix(in srgb, var(--accent) ${Math.round(4 + 16 * secs)}%, transparent)`;
  };
  return (
    <div className="diff-scroll" ref={ref}>
      <div style={{ height: lines.length * BLAME_H, position: "relative", minWidth: "max-content" }}>
        <div style={{ position: "absolute", top: first * BLAME_H, left: 0, right: 0 }}>
          {lines.slice(first, last).map((l) => (
            <div key={l.no} data-line={l.no} data-focused={targetLine === l.no || undefined} className={`diff-line blame-line ${l.startsBlock && l.no > 1 ? "block-start" : ""}`} style={{ height: BLAME_H, background: targetLine === l.no ? "color-mix(in srgb, var(--accent) 22%, transparent)" : undefined }}>
              <span
                className="blame-gutter"
                style={{ background: age(l), cursor: l.startsBlock && !isUncommittedLine(l) ? "pointer" : undefined }}
                data-tip={l.startsBlock ? (isUncommittedLine(l) ? t("Uncommitted line") : tip(l.summary, t("{0} · {1}\nClick to show this commit in the graph", l.author, longDate(l.date)))) : undefined}
                onClick={() => {
                  if (!l.startsBlock || isUncommittedLine(l)) return;
                  store.closeFileInspect();
                  store.reveal(l.sha);
                }}
              >
                {l.startsBlock &&
                  (isUncommittedLine(l) ? (
                    <span style={{ color: "var(--orange)" }}>{t("Not committed")}</span>
                  ) : (
                    <>
                      <Avatar name={l.author} email={l.email} size={14} url={avatars.url(l.email, l.author)} />
                      <span className="ellipsis" style={{ width: 80 }}>
                        {l.author}
                      </span>
                      <span className="muted">{shortDate(l.date)}</span>
                      <span className="spacer" />
                      <span className="muted">{short(l.sha)}</span>
                    </>
                  ))}
              </span>
              <span className="no">{l.no}</span>
              <span style={{ paddingLeft: 8 }}>{l.text || " "}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
