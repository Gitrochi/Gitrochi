import { Check, ChevronDown, ChevronRight, ChevronUp, Ellipsis, Folder, MessageSquare, Space } from "lucide-react";
import { type CSSProperties, type ReactNode, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { fileDir, fileName, StatusBadge } from "@/entities/git";
import { type PullRequestReview, type ReviewFile, reviewFileChange } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { showMenuBelow, Spinner, StatusPill } from "@/shared/ui";
import { folderLabel, splitAllowed, threadCount, treeWidth, viewedKey, withViewed } from "../lib/pull-request-page";
import { FileViewToggle, treeRows, useFileViewMode } from "./FileList";
import { ReviewDraftPanel } from "./ReviewPanels";

const viewedSetting = "pullRequestViewed";

/**
 * The Changed files tab: the request's files as a list or a folder tree, and on the Pull requests page the open
 * file's diff beside it under one 44px header. In the repository inspector there is no room for the diff, so a file
 * opens on the page instead. macOS: PullRequestFilesView.swift.
 */
export function PullRequestFilesView({ store, number, review, compact, active, diff }: {
  store: RepoStore; number: number; review: PullRequestReview | null;
  /** the narrow form: a 280px tree without the per-file counts */
  compact: boolean;
  /** the tab is showing */
  active: boolean;
  /** the diff view to draw beside the tree, on the Pull requests page; absent in the inspector */
  diff?: (split: boolean) => ReactNode;
}) {
  useObserve(settings);
  const mode = useFileViewMode();
  const [collapsed, setCollapsed] = useState(new Set<string>());
  const [diffWidth, setDiffWidth] = useState(0);
  const pane = useRef<HTMLElement>(null);
  const listed = review?.files ?? [];
  // "2 / 6", J and K follow the order the rows are drawn in: the tree's when it shows, else the server's
  const files = useMemo(() => {
    if (mode !== "tree") return listed;
    const byPath = new Map(listed.map((file) => [file.path, file]));
    return treeRows(listed.map(reviewFileChange), new Set()).flatMap((row) => (row.kind === "file" ? [byPath.get(row.change.path)!] : []));
  }, [review, mode]);
  const source = store.diffSource?.kind === "review" && store.diffSource.number === number ? store.diffSource : null;
  const index = source ? files.findIndex((file) => file.path === source.change.path) : -1;
  const current = index >= 0 ? files[index] : null;
  const marksKey = review ? viewedKey(review.repositoryKey, number, review.headSHA) : "";
  const viewed = new Set(settings.get<Record<string, string[]>>(viewedSetting, {})[marksKey] ?? []);
  const setViewed = (path: string, value: boolean) => settings.set(viewedSetting, withViewed(settings.get<Record<string, string[]>>(viewedSetting, {}), marksKey, path, value));
  const open = (file: ReviewFile) => store.openReviewFile(number, file);
  const step = (by: number) => { const next = files[index + by]; if (next) open(next); };
  // On the page the tab never shows an empty diff: the first file opens, and a reloaded review replaces a stale patch
  useEffect(() => {
    if (!diff || !active || !files.length) return;
    if (!source) open(files[0]);
    else if (current && (current.patch ?? "") !== source.patch) open(current);
  }, [!!diff, active, review, source?.change.path]);
  useLayoutEffect(() => {
    const element = pane.current;
    if (!element) return;
    const observer = new ResizeObserver(() => setDiffWidth(element.clientWidth));
    observer.observe(element); setDiffWidth(element.clientWidth);
    return () => observer.disconnect();
  }, [!!diff]);
  // J and K walk the files, as the header's buttons say, unless the keys belong to a field or a dialog
  useEffect(() => {
    if (!diff || !active) return;
    const onKey = (event: KeyboardEvent) => {
      const element = event.target as HTMLElement | null;
      if (event.ctrlKey || event.metaKey || event.altKey || element?.closest?.("input, textarea, select, [contenteditable], .xterm") || document.querySelector(".modal-backdrop")) return;
      const key = event.key.toLowerCase();
      if (key === "j") { event.preventDefault(); step(1); } else if (key === "k") { event.preventDefault(); step(-1); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
  const rows = useMemo(() => (mode === "tree" ? treeRows(files.map(reviewFileChange), collapsed) : []), [mode, review, collapsed]);
  const fileRow = (file: ReviewFile, depth: number | null) => {
    const name = fileName(file.path), selected = current?.path === file.path, threads = review ? threadCount(review.comments, file.path) : 0, seen = viewed.has(file.path);
    const stats = `+${file.additions} −${file.deletions}`;
    return <div key={file.path} className={`pr-file-row ${selected ? "selected" : ""}`} style={{ paddingLeft: depth == null ? 6 : 24 + depth * 14 }} title={compact ? `${name}  ${stats}` : undefined}>
      <button type="button" className="pr-file-open review-file" aria-current={selected} data-tip={file.patch ? undefined : t("Binary or too large — view it in the browser")} onClick={() => open(file)}>
        <StatusBadge kind={file.kind}/>
        {file.oldPath && <span className="pr-file-from">{fileName(file.oldPath)} →</span>}
        <span className="pr-file-name">{name}</span>
        {depth == null && <span className="pr-file-from" title={fileDir(file.path)}>{folderLabel(file.path)}</span>}
      </button>
      {threads > 0 && <span className="pr-file-threads" role="img" aria-label={threads === 1 ? t("1 thread") : t("{0} threads", threads)}><MessageSquare size={11}/>{threads}</span>}
      {!compact && <span className="pr-stat mono"><span className="a">+{file.additions}</span> <span className="d">−{file.deletions}</span></span>}
      <button type="button" role="checkbox" className="pr-viewed" aria-checked={seen} aria-label={t("Viewed {0}", name)} data-tip={t("Viewed {0}", name)} onClick={() => setViewed(file.path, !seen)}><span className="pr-viewed-box">{seen && <Check size={11} strokeWidth={3}/>}</span></button>
    </div>;
  };
  const tree = <section className="pr-tree" style={diff ? { "--pr-tree-width": `${treeWidth(compact)}px` } as CSSProperties : undefined} aria-label={t("Changed files")}>
    <div className="pr-tree-head"><span className="pr-cap grow">{t("{0} viewed", files.filter((file) => viewed.has(file.path)).length)}</span><FileViewToggle/></div>
    {!review ? store.reviewLoading && <Spinner size={14}/> : !files.length && <p className="pr-cap">{t("No changed files")}</p>}
    <div className="pr-tree-rows" role="group">
      {mode === "tree" ? rows.map((row) => row.kind === "folder"
        ? <button type="button" key={row.id} className="pr-folder-row" aria-expanded={!collapsed.has(row.path)} style={{ paddingLeft: 6 + row.depth * 14 }} onClick={() => setCollapsed((value) => { const next = new Set(value); if (!next.delete(row.path)) next.add(row.path); return next; })}>
          {collapsed.has(row.path) ? <ChevronRight size={12}/> : <ChevronDown size={12}/>}<Folder size={13}/><span className="ellipsis">{row.name}</span>{row.files.length > 1 && <StatusPill tone="neutral">{row.files.length}</StatusPill>}
        </button>
        : fileRow(files.find((file) => file.path === row.change.path)!, row.depth))
        : files.map((file) => fileRow(file, null))}
    </div>
    {review && <ReviewDraftPanel store={store} number={number}/>}
  </section>;
  if (!diff) return <div className="pr-files pr-files-only">{tree}</div>;
  const allowed = splitAllowed(diffWidth), split = store.diffSplit && allowed, reason = t("Split needs a diff at least 1000 px wide");
  return <div className="pr-files" data-compact={compact}>
    {tree}
    <section className="pr-diff" ref={pane} aria-label={current ? fileName(current.path) : t("Changed files")}>
      {current && <div className="pr-diff-head">
        <div className="pr-diff-file"><StatusBadge kind={current.kind}/><span className="pr-diff-name">{fileName(current.path)}</span><span className="pr-diff-dir" title={fileDir(current.path)}>{folderLabel(current.path)}</span></div>
        <div className="pr-diff-nav">
          <span className="pr-diff-count mono">{index + 1} / {files.length}</span>
          <button type="button" className="pr-icon-button" disabled={index <= 0} aria-label={t("Previous file (K)")} aria-keyshortcuts="K" data-tip={t("Previous file (K)")} onClick={() => step(-1)}><ChevronUp size={13}/></button>
          <button type="button" className="pr-icon-button" disabled={index >= files.length - 1} aria-label={t("Next file (J)")} aria-keyshortcuts="J" data-tip={t("Next file (J)")} onClick={() => step(1)}><ChevronDown size={13}/></button>
        </div>
        <span id="request-split-reason" hidden>{reason}</span>
        <div className="segmented pr-diff-layout" role="group" aria-label={t("Diff layout")}>
          <button type="button" className={split ? "" : "on"} aria-pressed={!split} onClick={() => store.setDiffSplit(false)}>{t("Unified")}</button>
          {/* a disabled button shows no tip of its own, so the reason sits on its wrapper */}
          <span className="pr-split" data-tip={allowed ? undefined : reason}><button type="button" className={split ? "on" : ""} aria-pressed={split} disabled={!allowed} aria-describedby={allowed ? undefined : "request-split-reason"} onClick={() => store.setDiffSplit(true)}>{t("Split")}</button></span>
        </div>
        <button type="button" className={`pr-icon-button ${store.diffIgnoreWhitespace ? "on" : ""}`} aria-pressed={store.diffIgnoreWhitespace} aria-label={t("Hide whitespace")} data-tip={t("Hide whitespace")} onClick={() => store.setDiffIgnoreWhitespace(!store.diffIgnoreWhitespace)}><Space size={13}/></button>
        <button type="button" className="pr-text-button" disabled={store.diffLoading || store.diff?.isBinary} data-tip={t("Ask questions about the selected changes")} onClick={() => void store.openChangeQuestion()}>{t("Ask AI…")}</button>
        <button type="button" className="pr-icon-button" aria-label={t("More file actions")} aria-haspopup="menu" data-tip={t("More file actions")} onClick={(event) => showMenuBelow(event.currentTarget, [
          { label: t("Show in Explorer"), onClick: () => store.revealFile(reviewFileChange(current)) },
          { label: t("Copy path"), onClick: () => store.copy(current.path) },
        ])}><Ellipsis size={14}/></button>
      </div>}
      <div className="pr-diff-body">{source ? diff(split) : review ? !files.length ? null : <Spinner size={16}/> : store.reviewLoading && <Spinner size={16}/>}</div>
    </section>
  </div>;
}
