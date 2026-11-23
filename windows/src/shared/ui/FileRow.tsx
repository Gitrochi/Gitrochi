import { type KeyboardEvent, type MouseEvent, type ReactNode, useLayoutEffect, useRef, useState } from "react";
import { FileTypeIcon } from "./FileTypeIcon";
import { Check, ChevronDown, ChevronRight, Folder, MessageSquare } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { fileRowFolds } from "./file-row-folds";
import { HostedListTextButton } from "./HostedList";
import { StatusPill } from "./StatusPill";
import { LineStatText } from "./ui";
import "./file-row.css";

/** One level of the tree every file list shares; a file's badge starts under its folder's glyph. macOS: FileTree.indent */
export const fileTreeIndent = 14;
export const fileIndent = (depth: number | null) => (depth == null ? 8 : 6 + depth * fileTreeIndent + 18);

/**
 * The one changed-file row (docs/design.md, Shared components): working changes, a commit's files, a pull request's
 * files and Compare all draw this. 28px tall with a 6px radius; the status badge, the name at 13px, the folder and
 * the rename caption at 11px, then the counts or a neutral pill, the review marks and the row's own action.
 * The badge and the rename caption come from the caller (StatusBadge, renameCaption), as the diff header's badge does.
 * macOS: FileRow in Views/Shared/Theme.swift
 */
export function FileRow({ path, oldPath, badge, rename, selected, showFolder = true, stat, note, dimmed = false, threads = 0, indent = 8, action, viewed, open, space, menu, tip }: {
  path: string;
  /** Where a renamed or copied file came from, for the hover tip */
  oldPath?: string | null;
  badge: ReactNode;
  /** "find.md → search.md", after the folder */
  rename?: string | null;
  selected: boolean;
  showFolder?: boolean;
  stat?: { added: number | null; deleted: number | null };
  /** A neutral pill in place of the counts ("Too large") */
  note?: string;
  /** Reviewed already: the name steps back */
  dimmed?: boolean;
  threads?: number;
  /** The room before the badge; a tree passes fileIndent(depth) */
  indent?: number;
  /** An icon action shows on hover or focus only; one with a label is words that are always there (Mark as resolved) */
  action?: { icon: ReactNode; tip: string; label?: string; run: () => void };
  /** The review's Viewed box; left out where nothing is reviewed */
  viewed?: { on: boolean; set: (on: boolean) => void };
  open: () => void;
  /** What Space does on the focused row: stage, or tick Viewed; it opens the file when the row has neither */
  space?: () => void;
  menu?: (event: MouseEvent) => void;
  /** The hover tip, when the path alone does not say enough */
  tip?: string;
}) {
  const row = useRef<HTMLDivElement>(null), words = useRef<HTMLButtonElement>(null), measured = useRef("");
  const [width, setWidth] = useState(0), [level, setLevel] = useState(0), [active, setActive] = useState(false);
  const cut = path.lastIndexOf("/"), name = path.slice(cut + 1), folder = cut < 0 ? "" : path.slice(0, cut);
  const folds = fileRowFolds(showFolder ? folder : "", !!rename, !!note || !!stat);
  const fold = folds[Math.min(level, folds.length - 1)];
  const hoverAction = action && !action.label && active;
  // what the row's width depends on besides the room it has
  const content = [path, rename, showFolder, stat?.added, stat?.deleted, note, threads, indent, !!viewed, action?.label, !!hoverAction].join("|");
  useLayoutEffect(() => {
    const element = row.current;
    if (!element) return;
    const observer = new ResizeObserver(() => setWidth(element.clientWidth));
    observer.observe(element); setWidth(element.clientWidth);
    return () => observer.disconnect();
  }, []);
  // The widest form that fits: start over when the room or the content changes, then fold one step at a time
  useLayoutEffect(() => {
    // the words take what the marks and actions beside them leave, and report what does not fit
    const element = words.current;
    if (!element) return;
    const key = `${width}|${content}`;
    if (measured.current !== key) { measured.current = key; if (level !== 0) { setLevel(0); return; } }
    if (level < folds.length - 1 && element.scrollWidth > element.clientWidth) setLevel(level + 1);
  });
  const onKey = (event: KeyboardEvent) => {
    if (event.key !== " " || !space) return;
    // the button would also open the file when the key comes up
    event.preventDefault();
    if (event.type === "keydown") space();
  };
  return (
    <div ref={row} className={`file-row status-tone${selected ? " selected" : ""}${dimmed ? " viewed" : ""}`} style={{ paddingLeft: indent, paddingRight: viewed ? 2 : undefined }}
      data-fold={level} data-tip={tip ?? (oldPath ? `${oldPath} → ${path}` : path)}
      onClick={open} onContextMenu={menu}
      onMouseEnter={() => setActive(true)} onMouseLeave={(event) => setActive(event.currentTarget.contains(document.activeElement))}
      onFocus={() => setActive(true)} onBlur={(event) => { if (!event.currentTarget.contains(event.relatedTarget)) setActive(event.currentTarget.matches(":hover")); }}>
      <button type="button" ref={words} className="file-row-open" aria-current={selected || undefined} onKeyDown={onKey} onKeyUp={onKey}>
        {badge}
        <FileTypeIcon path={path} />
        {/* the semibold width is kept either way, so selecting a row never moves what follows the name */}
        <span className={`file-row-name${fold.cut ? " cut" : ""}`} data-name={name}><span>{name}</span></span>
        {fold.folder && <span className="file-row-folder" title={folder}>{fold.folder}</span>}
        {fold.rename && rename && <span className="file-row-folder file-row-rename">{rename}</span>}
        <span className="file-row-space" />
        {fold.stats && (note ? <StatusPill tone="neutral" className="file-row-pill">{note}</StatusPill>
          : stat && (stat.added !== null && stat.deleted !== null ? <LineStatText added={stat.added} deleted={stat.deleted} zeros />
            : <StatusPill tone="neutral" className="file-row-pill">{t("Binary")}</StatusPill>))}
      </button>
      {threads > 0 && <span className="file-row-threads" role="img" aria-label={threads === 1 ? t("1 thread") : t("{0} threads", threads)}><MessageSquare size={11} />{threads}</span>}
      {action?.label && <HostedListTextButton className="file-row-text-action" onClick={(event) => { event.stopPropagation(); action.run(); }}>{action.label}</HostedListTextButton>}
      {viewed && (
        <button type="button" role="checkbox" className="file-row-viewed" aria-checked={viewed.on} aria-label={t("Viewed {0}", name)} data-tip={t("Viewed {0}", name)}
          onClick={(event) => { event.stopPropagation(); viewed.set(!viewed.on); }}>
          <span className="file-row-viewed-box">{viewed.on && <Check size={11} strokeWidth={3} />}</span>
        </button>
      )}
      {hoverAction && (
        <button type="button" className="file-row-act" aria-label={action.tip} data-tip={action.tip} onClick={(event) => { event.stopPropagation(); action.run(); }}>
          {action.icon}
        </button>
      )}
    </div>
  );
}

/**
 * A folder of the tree every file list shares: 28px, a chevron in a 10px slot, the folder glyph and the name in
 * medium, all neutral, then a count pill when it holds more than one file. macOS: FileFolderRow
 */
export function FileFolderRow({ name, count, depth, expanded, toggle, action, menu }: {
  name: string;
  count: number;
  depth: number;
  expanded: boolean;
  toggle: () => void;
  action?: { icon: ReactNode; tip: string; run: () => void };
  menu?: (event: MouseEvent) => void;
}) {
  return (
    <div className="file-folder-row" style={{ paddingLeft: 6 + depth * fileTreeIndent }} onClick={toggle} onContextMenu={menu}>
      <button type="button" className="file-folder-open" aria-expanded={expanded}>
        <span className="file-folder-chevron">{expanded ? <ChevronDown size={10} /> : <ChevronRight size={10} />}</span>
        <Folder size={13} />
        <span className="file-folder-name">{name}</span>
        {/* a folder holding a single file needs no count */}
        {count > 1 && <StatusPill tone="neutral">{count}</StatusPill>}
      </button>
      {action && (
        <button type="button" className="file-row-act" aria-label={action.tip} data-tip={action.tip} onClick={(event) => { event.stopPropagation(); action.run(); }}>
          {action.icon}
        </button>
      )}
    </div>
  );
}
