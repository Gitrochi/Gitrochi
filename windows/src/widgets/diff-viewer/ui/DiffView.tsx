import { CornerDownLeft, Equal, FileArchive, ImageOff, LockOpen, TriangleAlert } from "lucide-react";
import { FileText, Minus, Pencil, Plus, Trash2 } from "@/shared/icons";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { ConflictView } from "@/features/resolve-conflict";
import { type DiffDocument, type DiffLine, diffPath, diffSiblings, diffSides, modeSummary, sameDiffSource, short, type SplitRow, splitRows, StatusBadge } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { basename, joinPath, samePath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { sourceLanguage, useObserve } from "@/shared/lib";
import { Button, CodeText, DiffHeader, Empty, type MenuItem, Spinner, useFileViewMode } from "@/shared/ui";
import "./diff-viewer.css";

const LINE_H = 18;
const HUNK_H = 26;
/** The column a working diff keeps for the per-line stage button, between the line numbers and the +/− sign */
const STAGE_W = 24;

/**
 * 파일 하나의 변경 내용. 그래프 자리를 대신 차지하고, ← 또는 Esc 로 그래프로 돌아간다.
 * 한 줄로 / 나란히 보기, 공백 무시, 단어 단위 강조, 이미지 비교, 덩어리·줄 단위 스테이지. (맥 버전 DiffView)
 */
export function DiffView({ store, chrome = true, split }: {
  store: RepoStore;
  /** false leaves out the header, for a page that draws its own header around the diff (Esc is the app's: shortcuts.ts) */
  chrome?: boolean;
  /** the layout when the page decides it, for example unified while the diff is too narrow to split */
  split?: boolean;
}) {
  useObserve(store);
  const source = store.diffSource!;
  const c = source.change;
  const subtitle =
    source.kind === "working"
      ? `${c.path} · ${c.kind === "conflicted" ? t("Conflict") : c.staged ? t("Staged") : t("Working tree")}`
      : source.kind === "commit"
        ? t("{0}{1} · commit {2}", c.oldPath ? c.oldPath + " → " : "", c.path, short(source.sha))
        : source.kind === "worktree"
          ? `${c.path} · ${t("Worktree: {0}", store.worktrees.find((w) => samePath(w.path, source.path))?.branch ?? basename(source.path))}`
          : `${c.oldPath ? c.oldPath + " → " : ""}${c.path} · ${store.target?.provider === "gitlab" ? "MR" : "PR"} #${source.number}`;
  const doc = store.diff;
  // a diff on the repository screen stands where the graph was, so its way back names the graph
  const backLabel = source.kind === "review" ? t("Back to conversation") : t("Graph");
  useObserve(settings);
  const tree = useFileViewMode() === "tree";
  // the files this one was opened among: the header's "2 / 6", and J and K
  const siblings = chrome ? diffSiblings(source, { status: store.status, detailSha: store.detail?.sha ?? null, detailFiles: store.detailFiles, tree }) : [];
  const index = siblings.findIndex((item) => sameDiffSource(item, source));
  const step = (by: number) => { const next = siblings[index + by]; if (next) store.openDiff(next); };
  // J and K walk the files, as the header's buttons say, unless the keys belong to a field, the terminal or a dialog
  useEffect(() => {
    if (index < 0) return;
    const onKey = (event: KeyboardEvent) => {
      const element = event.target as HTMLElement | null;
      if (event.ctrlKey || event.metaKey || event.altKey || element?.closest?.("input, textarea, select, [contenteditable], .xterm") || document.querySelector(".modal-backdrop")) return;
      const key = event.key.toLowerCase();
      if (key === "j") { event.preventDefault(); step(1); } else if (key === "k") { event.preventDefault(); step(-1); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
  const busy = !!store.busy, tools = c.kind !== "untracked" && source.kind !== "review" && source.kind !== "worktree";
  // More: what the header does not draw. Staging first, the file's history tools, where the file is, discarding last
  const more = (): MenuItem[] => [
    ...(source.kind === "working" ? [
      c.kind === "conflicted" ? { label: t("Mark as resolved"), disabled: busy, onClick: () => void store.stage([c]) }
        : c.staged ? { label: t("Unstage"), disabled: busy, onClick: () => void store.unstage([c]) }
        : { label: t("Stage"), disabled: busy, onClick: () => void store.stage([c]) },
      "divider" as const,
    ] : []),
    ...(tools ? [
      { label: t("File history"), onClick: () => store.openFileHistory(c.path) },
      ...(c.kind !== "deleted" ? [{ label: t("Show blame"), onClick: () => store.openBlame(c.path, source.kind === "commit" ? source.sha : null) }] : []),
      { label: t("Trace lines…"), disabled: store.diffLoading || !!doc?.isBinary, onClick: () => store.openSelectedLineHistory() },
      "divider" as const,
    ] : []),
    { label: t("Show in Explorer"), onClick: () => (source.kind === "worktree" ? void ipc.reveal(joinPath(source.path, c.path)) : store.revealFile(c)) },
    { label: t("Copy path"), onClick: () => store.copy(c.path) },
    ...(source.kind === "working" && !c.staged && c.kind !== "conflicted" ? ["divider" as const, { label: t("Discard changes…"), danger: true, disabled: busy, onClick: () => store.confirmDiscard(c) }] : []),
  ];

  return (
    <div className="col grow">
      {chrome && <DiffHeader
        back={{ label: backLabel, tip: source.kind === "review" ? `${backLabel} (Esc)` : t("Back to graph (Esc)"), onClick: () => store.closeDiff() }}
        badge={<StatusBadge kind={c.kind} />}
        path={c.path}
        help={subtitle}
        position={index < 0 ? null : { index, count: siblings.length, step }}
        layout={{ split: split ?? store.diffSplit, set: (value) => store.setDiffSplit(value) }}
        whitespace={{ hidden: store.diffIgnoreWhitespace, set: (value) => store.setDiffIgnoreWhitespace(value) }}
        ask={{ disabled: store.diffLoading || !!doc?.isBinary, run: () => void store.openChangeQuestion() }}
        more={more}
      />}
      {source.kind === "working" && c.kind === "conflicted" ? (
        <ConflictView store={store} change={c} />
      ) : !doc ? (
        <div className="empty">
          <Spinner size={20} />
        </div>
      ) : doc.error ? (
        <Empty icon={<TriangleAlert size={30} />} title={t("Couldn't load the changes")} detail={doc.error} />
      ) : store.diffImages ? (
        <ImageDiff old={store.diffImages.old} now={store.diffImages.new} />
      ) : doc.isBinary ? (
        <Empty icon={<FileArchive size={30} />} title={t("Binary file")} detail={t("This isn't a text file, so a line-by-line comparison isn't shown.")} />
      ) : !doc.lines.length ? (
        <DiffEmptyState doc={doc} ignoreWhitespace={store.diffIgnoreWhitespace} />
      ) : (
        <DiffBody
          store={store}
          doc={doc}
          split={split ?? store.diffSplit}
          editable={store.canEditDiffLines}
          staged={store.diffSource?.kind === "working" && store.diffSource.change.staged}
        />
      )}
    </div>
  );
}

/** 내용 줄이 없는 diff: 새 빈 파일·이름만·권한만 바뀐 경우 등을 알맞게 알린다 */
export function DiffEmptyState({ doc, ignoreWhitespace = false }: { doc: DiffDocument; ignoreWhitespace?: boolean }) {
  const i = doc.info ?? {};
  const mode = modeSummary(i);
  const rename = i.renameFrom && i.renameTo ? `${i.renameFrom} → ${i.renameTo}` : null;
  const [icon, title, detail] = i.newFile
    ? [<FileText size={30} />, t("Empty file"), t("A new file with no content.")]
    : i.deletedFile
      ? [<Trash2 size={30} />, t("An empty file was deleted"), t("The deleted file had no content.")]
      : rename && mode
        ? [<Pencil size={30} />, t("Only the name and permissions changed"), t("{0}\nPermissions {1}", rename, mode)]
        : rename
          ? [<Pencil size={30} />, t("Only the name changed"), t("{0}\nThe content is unchanged.", rename)]
          : mode
            ? [<LockOpen size={30} />, t("Only permissions changed"), mode]
            : [
                <Equal size={30} />,
                t("No changes to show"),
                ignoreWhitespace ? t("Only whitespace changed (turn off Ignore whitespace to see it).") : t("Only permissions or the name may have changed, without content changes."),
              ];
  return <Empty icon={icon} title={title} detail={detail} />;
}

/** 이름·권한이 바뀌었으면 줄 목록 위에 한 줄로 */
function FileInfoBar({ doc }: { doc: DiffDocument }) {
  const i = doc.info;
  const mode = modeSummary(i);
  const rename = i?.renameFrom && i.renameTo ? `${i.renameFrom} → ${i.renameTo}${i.similarity !== undefined && i.similarity < 100 ? t(" · {0}% similar", i.similarity) : ""}` : null;
  if (!rename && !mode) return null;
  return (
    <div className="diff-info">
      {rename && (
        <span className="ellipsis">
          <Pencil size={12} /> {" "}{t("Renamed {0}", rename)}</span>
      )}
      {mode && (
        <span className="ellipsis">
          <LockOpen size={12} /> {" "}{t("Permissions changed {0}", mode)}</span>
      )}
    </div>
  );
}

/** 줄 번호 칸 너비: 가장 큰 번호의 자릿수에 맞춘다 */
function numberWidth(doc: DiffDocument) {
  let max = 0;
  for (const l of doc.lines) max = Math.max(max, l.oldNo ?? 0, l.newNo ?? 0);
  return Math.max(2, String(max).length) * 7.5 + 14;
}

/** 줄바꿈될 높이 어림(재기 전): 고정폭 글꼴에서 한글 등 넓은 글자는 두 칸 */
function estimateLines(text: string, columns: number) {
  if (text.length < columns / 2) return 1;
  let w = 0;
  for (const c of text) w += c.charCodeAt(0) > 0x1100 ? 2 : 1;
  return Math.max(1, Math.ceil(w / Math.max(8, columns)));
}

const CHAR_W = 7.2;

/**
 * 보이는 줄만 그리는 diff 본문. 긴 줄은 칸 안에서 줄바꿈해 가로로 밀리지 않고 모두 보인다.
 * 줄 높이는 처음엔 어림하고, 그려진 줄은 재서 고친다. 파일 히스토리에서도 쓴다.
 */
export function DiffBody({ store, doc, split, editable, staged }: { store: RepoStore; doc: DiffDocument; split: boolean; editable: boolean; staged: boolean }) {
  const sides = useMemo(() => diffSides(doc.lines), [doc]);
  // one language per document: a diff of several files is left uncoloured
  const language = useMemo(() => (doc.multipleFiles ? "Plain text" : sourceLanguage(diffPath(doc.header) ?? "")), [doc]);
  // 새 파일·지운 파일처럼 한쪽만 있으면 나란히 보기라도 한 칸으로(빈 반쪽 없이)
  const halves = split && sides.old && sides.new;
  const rows: SplitRow[] = useMemo(
    () => (halves ? splitRows(doc.lines) : doc.lines.map((l, i) => (l.kind === "hunk" || l.kind === "meta" ? { full: i } : { left: i }))),
    [doc, halves],
  );
  const noW = useMemo(() => numberWidth(doc), [doc]);

  const ref = useRef<HTMLDivElement>(null);
  const winRef = useRef<HTMLDivElement>(null);
  const [vp, setVp] = useState({ top: 0, height: 800, width: 800 });
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const update = () => setVp({ top: el.scrollTop, height: el.clientHeight, width: el.clientWidth });
    update();
    const ro = new ResizeObserver(update);
    ro.observe(el);
    el.addEventListener("scroll", update, { passive: true });
    return () => {
      ro.disconnect();
      el.removeEventListener("scroll", update);
    };
  }, []);
  useLayoutEffect(() => {
    if (ref.current) ref.current.scrollTop = 0;
  }, [doc]);

  // 잰 높이: 문서·보기·너비가 바뀌면 다시 잰다
  const key = `${halves}|${Math.round(vp.width)}`;
  const measured = useRef({ doc, key, h: new Map<number, number>() });
  if (measured.current.doc !== doc || measured.current.key !== key) measured.current = { doc, key, h: new Map() };
  const [version, bump] = useState(0);

  const offsets = useMemo(() => {
    const gutter = (halves ? noW : (sides.old ? noW : 0) + (sides.new ? noW : 0)) + (editable ? STAGE_W : 0) + 22 + 6;
    const columns = Math.floor(((halves ? vp.width / 2 : vp.width) - gutter) / CHAR_W);
    const est = (r: SplitRow) => {
      if (r.full !== undefined) return doc.lines[r.full].kind === "hunk" ? HUNK_H : LINE_H;
      const a = r.left !== undefined ? estimateLines(doc.lines[r.left].text, columns) : 1;
      const b = r.right !== undefined ? estimateLines(doc.lines[r.right].text, columns) : 1;
      return Math.max(a, b) * LINE_H;
    };
    const o = [0];
    rows.forEach((r, i) => o.push(o[i] + (measured.current.h.get(i) ?? est(r))));
    return o;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows, doc, halves, sides, noW, editable, vp.width, version]);

  const find = (y: number) => {
    let lo = 0,
      hi = rows.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (offsets[mid + 1] <= y) lo = mid + 1;
      else hi = mid;
    }
    return lo;
  };
  const first = Math.max(0, find(vp.top) - 20);
  const last = Math.min(rows.length, find(vp.top + vp.height) + 20);
  const total = offsets[rows.length];

  // 그려진 줄의 실제 높이를 재서, 어림과 다르면 위치를 다시 계산
  useLayoutEffect(() => {
    const win = winRef.current;
    if (!win) return;
    let changed = false;
    Array.from(win.children).forEach((el, k) => {
      const h = Math.round((el as HTMLElement).getBoundingClientRect().height);
      const i = first + k;
      if (offsets[i + 1] - offsets[i] !== h) changed = true;
      measured.current.h.set(i, h);
    });
    if (changed) bump((v) => v + 1);
  });

  const lineCell = (i: number | undefined, side: "left" | "right" | "both") => {
    if (i === undefined) return <div className="diff-line empty-cell" />;
    const l = doc.lines[i];
    const selectable = editable && (l.kind === "added" || l.kind === "removed");
    const source = store.diffSource;
    const reviewSide = side === "left" && halves ? "LEFT" : l.newNo != null ? "RIGHT" : "LEFT";
    const reviewLine = reviewSide === "LEFT" ? l.oldNo : l.newNo;
    const commentable = source?.kind === "review" && store.diff === doc && !store.fileInspect && !doc.combined && !doc.multipleFiles
      && reviewLine != null && l.kind !== "hunk" && l.kind !== "meta";
    return (
      <div
        className={`diff-line ${l.kind} ${store.diffSelection.has(i) ? "selected" : ""} ${selectable ? "selectable" : ""}`}
        data-tip={selectable ? t("Click to select this line (Shift: range) — you can stage only the selected lines") : undefined}
        onClick={selectable ? (e) => store.toggleDiffLine(i, e.shiftKey) : undefined}
      >
        {commentable && <button type="button" className="review-line-add" aria-label={t("Add review comment on line {0}", reviewLine!)} title={t("Add review comment")}
          disabled={store.reviewBusy || store.reviewLoading}
          onClick={(e) => { e.stopPropagation(); store.addReviewDraft(source.number, source.change.path, reviewLine!, reviewSide, l.oldNo ?? undefined); }}>+</button>}
        {(side === "left" || (side === "both" && sides.old)) && <span className="no">{l.oldNo ?? ""}</span>}
        {(side === "right" || (side === "both" && sides.new)) && <span className="no">{l.newNo ?? ""}</span>}
        {editable && (
          <span className="diff-stage-gutter">
            {selectable && (
              <button type="button" className="diff-stage-line" aria-label={staged ? t("Unstage line") : t("Stage line")} data-tip={staged ? t("Unstage line") : t("Stage line")}
                disabled={store.busy != null}
                onClick={(e) => { e.stopPropagation(); void store.applyLines(staged ? "unstage" : "stage", l.hunk!, i); }}>
                <span>{staged ? <Minus size={10} /> : <Plus size={10} />}</span>
              </button>
            )}
          </span>
        )}
        <span className="mk">{l.kind === "added" ? "+" : l.kind === "removed" ? "−" : ""}</span>
        <LineText line={l} language={language} />
      </div>
    );
  };
  const gutter = (halves ? noW : (sides.old ? noW : 0) + (sides.new ? noW : 0)) + (editable ? STAGE_W : 0) + 22;

  return (
    <div className="col grow" style={{ minHeight: 0 }}>
      <FileInfoBar doc={doc} />
      <div className="diff-scroll" ref={ref} style={{ ["--no-w" as string]: `${noW}px` }}>
        <div style={{ height: total + (doc.truncated ? 40 : 0), position: "relative" }}>
          <div ref={winRef} style={{ position: "absolute", top: offsets[first], left: 0, right: 0 }}>
            {rows.slice(first, last).map((r, k) => {
              const n = first + k;
              if (r.full !== undefined) {
                const l = doc.lines[r.full];
                return l.kind === "hunk" && l.hunk !== undefined ? (
                  <HunkHeader key={n} store={store} line={l} hunk={l.hunk} editable={editable} staged={staged} />
                ) : (
                  <div key={n} className="diff-note" style={{ paddingLeft: gutter }}>
                    <CornerDownLeft size={11} /> {l.text}
                  </div>
                );
              }
              return halves ? (
                <div key={n} className="diff-split-row">
                  {lineCell(r.left, "left")}
                  {lineCell(r.right, "right")}
                </div>
              ) : (
                <div key={n}>{lineCell(r.left, "both")}</div>
              );
            })}
          </div>
          {doc.truncated && (
            <div className="muted" style={{ position: "absolute", top: total + 10, left: 12 }}>
              {t("… The diff is too long; only the beginning is shown")}</div>
          )}
        </div>
      </div>
    </div>
  );
}

/** The line with its syntax colours, and the changed words in bold (macOS: DiffLineRow.content) */
function LineText({ line, language }: { line: DiffLine; language: string }) {
  return <CodeText className="txt" text={line.text || " "} language={line.kind === "hunk" || line.kind === "meta" ? "Plain text" : language} marks={line.changes} markClassName="diff-word" />;
}


/** @@ 줄: 덩어리 위치 + (작업 트리 diff 면) 덩어리·고른 줄 스테이지·언스테이지·버리기 */
function HunkHeader({ store, line, hunk, editable, staged }: { store: RepoStore; line: DiffLine; hunk: number; editable: boolean; staged: boolean }) {
  const picked = editable ? store.selectedCount(hunk) : 0;
  return (
    <div className="diff-line hunk diff-hunk" style={{ height: HUNK_H }}>
      <span className="ellipsis grow" style={{ paddingLeft: 10 }}>
        {line.text}
      </span>
      {editable &&
        (staged ? (
          <Button size="small" onClick={() => void store.applyLines("unstage", hunk)} tip={picked ? t("Unstages only the selected lines") : t("Unstages this hunk")}>
            {picked ? t("Unstage selected lines ({0})", picked) : t("Unstage hunk")}
          </Button>
        ) : (
          <>
            <Button size="small" onClick={() => store.confirmDiscardLines(hunk)} tip={picked ? t("Discards the selected lines' changes from the working tree") : t("Discards this hunk's changes from the working tree")}>
              {picked ? t("Discard selected lines…") : t("Discard hunk…")}
            </Button>
            <Button
              size="small"
              kind="primary"
              onClick={() => void store.applyLines("stage", hunk)}
              tip={picked ? t("Stages only the selected lines") : t("Stages only this hunk (click changed lines to stage only those)")}
            >
              {picked ? t("Stage selected lines ({0})", picked) : t("Stage hunk")}
            </Button>
          </>
        ))}
    </div>
  );
}

/** 이미지 파일: 바뀌기 전과 후를 나란히(크기·용량 함께) */
function ImageDiff({ old, now }: { old: string | null; now: string | null }) {
  return (
    <div className="image-diff">
      <ImagePane title={t("Before")} src={old} tone="red" missing={t("This file was newly added.")} />
      <ImagePane title={t("After")} src={now} tone="green" missing={t("This file was deleted.")} />
    </div>
  );
}

function ImagePane({ title, src, tone, missing }: { title: string; src: string | null; tone: "red" | "green"; missing: string }) {
  const [size, setSize] = useState("");
  const bytes = src ? Math.round(((src.length - src.indexOf(",") - 1) * 3) / 4) : 0;
  const kb = bytes > 1024 * 1024 ? `${(bytes / 1024 / 1024).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return (
    <div className="image-pane">
      <div className="row">
        <span style={{ fontWeight: 600, color: `var(--${tone})` }}>{title}</span>
        <span className="spacer" />
        {src && (
          <span className="muted" style={{ fontSize: 11.5 }}>
            {size && `${size} · `}
            {kb}
          </span>
        )}
      </div>
      {src ? (
        <div className={`image-frame ${tone}`}>
          <img src={src} alt={title} onLoad={(e) => setSize(`${e.currentTarget.naturalWidth} × ${e.currentTarget.naturalHeight}`)} />
        </div>
      ) : (
        <Empty icon={<ImageOff size={28} />} title={t("None")} detail={missing} />
      )}
    </div>
  );
}
