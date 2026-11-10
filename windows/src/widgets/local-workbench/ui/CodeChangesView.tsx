import { useEffect, useMemo, useState, type CSSProperties, type ReactNode } from "react";
import { CornerDownLeft, Equal, FileArchive, TriangleAlert } from "lucide-react";
import { ChevronDown, ChevronUp, MoreHorizontal, Pilcrow } from "@/shared/icons";
import { diffSides, parseDiffAsync, splitRows, StatusBadge, type ChangeKind, type DiffDocument, type DiffLine } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { describe, type ExternalEditor } from "@/shared/platform";
import { Empty, IconButton, Segmented, showMenuBelow, Spinner } from "@/shared/ui";
import { comparisonChangeArgs, diffGaps, fileAtCommitArgs, fileChangeArgs, shortFolder, sourceLines, workingChangeArgs, type DiffGap } from "../lib/code-history";
import type { RepositoryEditorSource } from "./CodeExternalEditors";
import "./repository-code.css";

interface Props {
  store: RepoStore;
  repo: string;
  path: string;
  /** null for the working tree against HEAD */
  commit: string | null;
  /** The commit to compare from instead of the commit's first parent (the Compare page) */
  base?: string | null;
  /** A renamed file's path at base */
  oldPath?: string | null;
  /** Where the file sits among a list of files: the header's "2 / 6" with its previous and next buttons */
  position?: CodeFilePosition;
  /** The Compare page: More offers the file as it is in the working tree to an external editor */
  editors?: CodeWorkingFileEditors;
  read: (args: string[], repo: string) => Promise<string>;
  wrap: boolean;
  setWrap: (value: boolean) => void;
  /** The line count of the file as the commit has it, for the status bar */
  onLines: (count: number | null) => void;
}
/** Where the open file sits among a list of files, and the step to the one before or after it. macOS: CodeFilePosition */
/** The external editors and the working-tree check behind "Open in editor". macOS: RepositoryCodeChangesView.opensInEditor */
export interface CodeWorkingFileEditors { source: RepositoryEditorSource; exists: (repo: string, path: string) => Promise<boolean> }
export interface CodeFilePosition { index: number; count: number; step: (by: number) => void }
interface Cell { kind: DiffLine["kind"]; text: string; oldNo: number | null; newNo: number | null; changes?: Array<[number, number]> }
type Row = { key: string } & ({ fold: DiffGap } | { hunk: DiffLine } | { note: DiffLine } | { line: Cell } | { pair: [Cell | null, Cell | null] });
// a file's change in one commit is short; a generated file must not fill the page
const lineLimit = 5000, textLimit = 2_000_000;

/**
 * A wrapped line hangs its indentation, up to half of the row: the rows a long line continues on stay under its first
 * word instead of starting at the margin. (macOS: RepositoryCodeText.hangingIndent)
 */
export function hangingIndent(text: string, wrapping: boolean): CSSProperties | undefined {
  const indent = wrapping ? text.length - text.trimStart().length : 0;
  return indent ? { paddingLeft: `min(${indent}ch, 50%)`, textIndent: `calc(-1 * min(${indent}ch, 50%))` } : undefined;
}

/**
 * One file's change on the Code page, read only: a commit against its first parent, or the working tree against HEAD;
 * the Compare page shows a file's change from one commit to another with it. One 44px header, then the lines, with the
 * unchanged lines between hunks folded until asked for.
 * (macOS: RepositoryCodeChangesView)
 */
export function CodeChangesView({ store, repo, path, commit, base = null, oldPath = null, position, editors, read, wrap, setWrap, onLines }: Props) {
  const [doc, setDoc] = useState<DiffDocument | null>(null), [source, setSource] = useState<string[] | null>(null), [expanded, setExpanded] = useState<ReadonlySet<number>>(new Set());
  const ignoreWhitespace = store.diffIgnoreWhitespace, split = store.diffSplit;
  // the applications, and whether the file is in the working tree; null while unknown
  const [applications, setApplications] = useState<ExternalEditor[] | null>(null), [local, setLocal] = useState<boolean | null>(null);
  useEffect(() => {
    if (!editors) return;
    let current = true;
    setLocal(null);
    void editors.exists(repo, path).catch(() => false).then((value) => { if (current) setLocal(value); });
    if (!applications) void editors.source.list().catch(() => []).then((value) => { if (current) setApplications(value); });
    return () => { current = false; };
  }, [editors, repo, path]);
  useEffect(() => {
    let current = true;
    setDoc(null); setSource(null); setExpanded(new Set()); onLines(null);
    void (async () => {
      try {
        const args = commit ? base ? comparisonChangeArgs(base, commit, path, oldPath, ignoreWhitespace) : fileChangeArgs(commit, path, ignoreWhitespace) : workingChangeArgs(path, ignoreWhitespace);
        const value = await parseDiffAsync(await read(args, repo), lineLimit);
        if (!current) return;
        setDoc(value);
        if (!commit || value.isBinary || value.info?.deletedFile || !value.lines.length) return;
        const text = await read(fileAtCommitArgs(commit, path), repo).catch(() => null);
        if (!current || text == null || text.length > textLimit || text.includes("\0")) return;
        const lines = sourceLines(text);
        setSource(lines); onLines(lines.length);
      } catch { if (current) setDoc({ lines: [], isBinary: false, truncated: false, header: [], hunks: [], error: t("Couldn't read this commit's changes.") }); }
    })();
    return () => { current = false; };
  }, [repo, path, commit, base, oldPath, ignoreWhitespace, read]);

  // two halves wrap in place: scrolling them sideways together would hide one of them
  const halves = !!doc && split && diffSides(doc.lines).old && diffSides(doc.lines).new, wrapping = wrap || halves;
  const rows = useMemo(() => {
    if (!doc) return [];
    const gaps = source ? diffGaps(doc.hunks, source.length) : [], result: Row[] = [];
    const unchanged = (hunk: number) => {
      const gap = gaps.find((item) => item.hunk === hunk);
      if (!gap || !source) return;
      if (!expanded.has(hunk)) { result.push({ key: `fold-${hunk}`, fold: gap }); return; }
      for (let offset = 0; offset < gap.count && gap.newStart - 1 + offset < source.length; offset++) {
        const cell: Cell = { kind: "context", text: source[gap.newStart - 1 + offset], oldNo: gap.oldStart + offset, newNo: gap.newStart + offset };
        result.push(halves ? { key: `gap-${hunk}-${offset}`, pair: [cell, cell] } : { key: `gap-${hunk}-${offset}`, line: cell });
      }
    };
    const full = (line: DiffLine, index: number) => {
      if (line.kind === "hunk") { unchanged(line.hunk ?? 0); result.push({ key: `hunk-${index}`, hunk: line }); } else result.push({ key: `note-${index}`, note: line });
    };
    if (halves) splitRows(doc.lines).forEach((row, index) => {
      if (row.full !== undefined) full(doc.lines[row.full], row.full);
      else result.push({ key: `pair-${index}`, pair: [row.left === undefined ? null : doc.lines[row.left], row.right === undefined ? null : doc.lines[row.right]] });
    });
    else doc.lines.forEach((line, index) => { if (line.kind === "hunk" || line.kind === "meta") full(line, index); else result.push({ key: `line-${index}`, line }); });
    unchanged(doc.hunks.length);
    return result;
  }, [doc, source, expanded, halves]);

  const name = path.split("/").at(-1)!, folder = path.split("/").slice(0, -1).join("/");
  const kind: ChangeKind = doc?.info?.newFile ? "added" : doc?.info?.deletedFile ? "deleted" : doc?.info?.renameFrom && doc.info.renameTo ? "renamed" : "modified";
  const code = (cell: Cell): ReactNode => {
    const text = cell.text || " ";
    if (!cell.changes?.length) return text;
    // the words that changed inside a changed line, on a stronger fill
    const chars = [...text], parts: ReactNode[] = [];
    let position = 0;
    cell.changes.forEach(([start, end], index) => {
      if (start > position) parts.push(chars.slice(position, start).join(""));
      parts.push(<mark key={index}>{chars.slice(start, end).join("")}</mark>);
      position = end;
    });
    if (position < chars.length) parts.push(chars.slice(position).join(""));
    return parts;
  };
  // the sign says it as well as the colour
  const line = (cell: Cell | null, numbers: Array<number | null>) => cell
    ? <div className={`code-diff-line ${cell.kind}`}>{numbers.map((value, index) => <span className="no" key={index}>{value ?? ""}</span>)}<span className="sign">{cell.kind === "added" ? "+" : cell.kind === "removed" ? "−" : ""}</span><span className="code" style={hangingIndent(cell.text, wrapping)}>{code(cell)}</span></div>
    : <div className="code-diff-line none"/>;
  const scope = commit && base ? t("Changes from {0} to {1}", base.slice(0, 7), commit.slice(0, 7)) : commit ? t("Changes in {0} against its parent", commit.slice(0, 7)) : t("Uncommitted changes against HEAD");
  return <section className="code-changes" aria-label={scope}>
    <header className="code-changes-head">
      {doc && !doc.error && <StatusBadge kind={kind}/>}
      <strong>{name}</strong>
      {shortFolder(folder) && <span className="code-changes-folder" title={folder}>{shortFolder(folder)}</span>}
      <span className="spacer"/>
      {position && <span className="code-changes-nav">
        <span className="code-changes-count mono">{position.index + 1} / {position.count}</span>
        <IconButton icon={<ChevronUp size={13}/>} disabled={position.index <= 0} aria-label={t("Previous file (K)")} aria-keyshortcuts="K" tip={t("Previous file (K)")} onClick={() => position.step(-1)}/>
        <IconButton icon={<ChevronDown size={13}/>} disabled={position.index >= position.count - 1} aria-label={t("Next file (J)")} aria-keyshortcuts="J" tip={t("Next file (J)")} onClick={() => position.step(1)}/>
      </span>}
      <Segmented value={split ? "split" : "unified"} options={[{ value: "unified", label: t("Unified") }, { value: "split", label: t("Split") }]} onChange={(value) => store.setDiffSplit(value === "split")}/>
      <IconButton className={ignoreWhitespace ? "on" : ""} icon={<Pilcrow size={14}/>} aria-label={t("Hide whitespace")} aria-pressed={ignoreWhitespace} tip={t("Hide whitespace")} onClick={() => { store.setDiffIgnoreWhitespace(!ignoreWhitespace); store.changed(); }}/>
      <button type="button" className="code-text-button" disabled={!doc || doc.isBinary} data-tip={t("Ask questions about the selected changes")} onClick={() => { if (doc) void store.openChangeQuestion(false, { scope: commit && !base ? `${t("Commit")} ${commit}` : scope, path, doc }); }}>{t("Ask AI…")}</button>
      <IconButton icon={<MoreHorizontal size={14}/>} aria-label={t("More file actions")} aria-haspopup="menu" tip={t("More file actions")} onClick={(event) => showMenuBelow(event.currentTarget, [
        { label: t("Wrap lines"), checked: wrap, onClick: () => setWrap(!wrap) },
        ...(commit && !base ? [{ label: t("Show commit"), onClick: () => store.reveal(commit) }] : []),
        { label: t("Copy path"), onClick: () => store.copy(path) },
        // the working tree's file, not the compared version; a file that is not there cannot open
        ...(editors ? [{ label: t("Open in editor"), disabled: !local || !applications?.some((editor) => editor.available),
          tip: local === false ? t("The local file is missing or is not a regular file.") : applications && !applications.some((editor) => editor.available) ? t("This application is not installed.") : t("External editors open the current local file, not the revision preview."),
          submenu: (applications ?? []).map((editor) => ({ label: editor.id === "system" ? t("System default") : editor.name, disabled: !editor.available, tip: editor.available ? undefined : t("Not installed"),
            onClick: () => { editors.source.open(repo, editor.id, path).catch((cause) => { store.errorMessage = describe(cause); store.changed(); }); } })) }] : []),
      ])}/>
    </header>
    {!doc ? <div className="code-loading" role="status"><Spinner/></div>
      : doc.error ? <Empty icon={<TriangleAlert size={24}/>} title={t("Couldn't read the changes")} detail={doc.error}/>
      : doc.isBinary ? <Empty icon={<FileArchive size={24}/>} title={t("Binary file")}/>
      : !doc.lines.length ? <Empty icon={<Equal size={24}/>} title={t("No changes to show")} detail={ignoreWhitespace ? t("Only whitespace changed (turn off Ignore whitespace to see it).") : undefined}/>
      : <div className={`code-diff ${wrapping ? "wrap" : ""} ${halves ? "split" : ""}`} role="region" aria-label={t(halves ? "Side by side" : "Unified view")} tabIndex={0}>
        <div className="code-diff-sheet">
          {rows.map((row) => "fold" in row
            ? <div className="code-diff-fold" key={row.key}><button type="button" className="code-text-button" aria-label={t("Show {0} unchanged lines, {1} to {2}", row.fold.count, row.fold.newStart, row.fold.newStart + row.fold.count - 1)} onClick={() => setExpanded((value) => new Set(value).add(row.fold.hunk))}>⋯ {t("{0} unchanged lines", row.fold.count)}</button></div>
            : "hunk" in row ? <div className="code-diff-hunk status-tone" data-tone="info" key={row.key}>{row.hunk.text}</div>
            : "note" in row ? <div className="code-diff-note" key={row.key}><CornerDownLeft size={11}/>{row.note.text}</div>
            : "line" in row ? <div key={row.key}>{line(row.line, [row.line.oldNo, row.line.newNo])}</div>
            : <div className="code-diff-pair" key={row.key}>{line(row.pair[0], [row.pair[0]?.oldNo ?? null])}{line(row.pair[1], [row.pair[1]?.newNo ?? null])}</div>)}
          {doc.truncated && <p className="code-diff-more">{t("… The diff is too long; only the beginning is shown")}</p>}
        </div>
      </div>}
  </section>;
}
