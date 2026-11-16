import { type CSSProperties, type ReactNode, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { fileName, renameCaption, StatusBadge, treeRows } from "@/entities/git";
import { type PullRequestReview, type ReviewFile, reviewFileChange } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { DiffHeader, FileFolderRow, fileIndent, FileRow, FileViewToggle, requestFileView, Spinner, useFileViewMode } from "@/shared/ui";
import { splitAllowed, threadCount, treeWidth, viewedKey, withViewed } from "../lib/pull-request-page";
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
  const mode = useFileViewMode(...requestFileView);
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
  // the shared file row with the review's marks: threads, the counts where there is room for them, and Viewed
  const fileRow = (file: ReviewFile, depth: number | null) => {
    const seen = viewed.has(file.path);
    return <FileRow key={file.path} path={file.path} oldPath={file.oldPath} badge={<StatusBadge kind={file.kind}/>} rename={renameCaption(file)} selected={current?.path === file.path} showFolder={depth == null} indent={fileIndent(depth)}
      // a compact row has no room for the counts: they are in the tip
      stat={compact || !file.patch ? undefined : { added: file.additions, deleted: file.deletions }}
      note={compact || file.patch ? undefined : file.additions + file.deletions > 0 ? t("Too large") : t("Binary")}
      dimmed={seen} threads={review ? threadCount(review.comments, file.path) : 0}
      viewed={{ on: seen, set: (on) => setViewed(file.path, on) }}
      open={() => open(file)} space={() => setViewed(file.path, !seen)}
      tip={file.patch ? `${file.path}  +${file.additions} −${file.deletions}` : t("Binary or too large — view it in the browser")}/>;
  };
  const tree = <section className="pr-tree" style={diff ? { "--pr-tree-width": `${treeWidth(compact)}px` } as CSSProperties : undefined} aria-label={t("Changed files")}>
    <div className="pr-tree-head"><span className="pr-cap grow">{t("{0} viewed", files.filter((file) => viewed.has(file.path)).length)}</span><FileViewToggle view={requestFileView}/></div>
    {!review ? store.reviewLoading && <Spinner size={14}/> : !files.length && <p className="pr-cap">{t("No changed files")}</p>}
    <div className="pr-tree-rows" role="group">
      {mode === "tree" ? rows.map((row) => row.kind === "folder"
        ? <FileFolderRow key={row.id} name={row.name} count={row.files.length} depth={row.depth} expanded={!collapsed.has(row.path)}
          toggle={() => setCollapsed((value) => { const next = new Set(value); if (!next.delete(row.path)) next.add(row.path); return next; })}/>
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
      {current && <DiffHeader
        badge={<StatusBadge kind={current.kind}/>}
        path={current.path}
        position={{ index, count: files.length, step }}
        layout={{ split, set: (value) => store.setDiffSplit(value), disabledReason: allowed ? undefined : reason }}
        whitespace={{ hidden: store.diffIgnoreWhitespace, set: (value) => store.setDiffIgnoreWhitespace(value) }}
        ask={{ disabled: store.diffLoading || !!store.diff?.isBinary, run: () => void store.openChangeQuestion() }}
        more={() => [
          { label: t("Show in Explorer"), onClick: () => store.revealFile(reviewFileChange(current)) },
          { label: t("Copy path"), onClick: () => store.copy(current.path) },
        ]}
      />}
      <div className="pr-diff-body">{source ? diff(split) : review ? !files.length ? null : <Spinner size={16}/> : store.reviewLoading && <Spinner size={16}/>}</div>
    </section>
  </div>;
}
