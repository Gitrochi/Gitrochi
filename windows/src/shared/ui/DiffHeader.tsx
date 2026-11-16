import { type ReactNode, useLayoutEffect, useRef, useState } from "react";
import { ChevronDown, ChevronLeft, ChevronUp, MoreHorizontal, Pilcrow } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { type MenuItem, Segmented, showMenuBelow } from "./ui";
import { diffHeaderFolds } from "./diff-header-folds";
import "./diff-header.css";

/** Where the open file sits among a list of files, and the step to the one before or after it. macOS: CodeFilePosition */
export interface DiffFilePosition { index: number; count: number; step: (by: number) => void }

/**
 * The one diff header (docs/design.md, Shared components): a 44px row with the way back where the screen has one, the
 * status badge, the file name and its folder on the left; the file's position with previous and next, Unified | Split,
 * Hide whitespace, Ask AI… and More on the right. macOS: Shared/DiffHeader.swift
 */
export function DiffHeader({ back, badge, path, help, position, layout, whitespace, ask, accessory, more }: {
  back?: { label: string; tip: string; onClick: () => void };
  badge?: ReactNode;
  path: string;
  /** what the name says on hover instead of the whole path */
  help?: string;
  position?: DiffFilePosition | null;
  /** absent where the content has one layout only (blame); `disabledReason` says why Split cannot be chosen here */
  layout?: { split: boolean; set: (split: boolean) => void; disabledReason?: string };
  whitespace?: { hidden: boolean; set: (hidden: boolean) => void };
  ask?: { disabled?: boolean; run: () => void };
  /** the screen's own controls, before the layout (History | Blame) */
  accessory?: ReactNode;
  more: () => MenuItem[];
}) {
  const row = useRef<HTMLDivElement>(null), measured = useRef("");
  const [width, setWidth] = useState(0), [level, setLevel] = useState(0);
  const folds = diffHeaderFolds(path, { position: !!position, ask: !!ask, whitespace: !!whitespace });
  const fold = folds[Math.min(level, folds.length - 1)];
  const name = path.split("/").pop() ?? path, folder = path.split("/").slice(0, -1).join("/");
  // what the row's width depends on besides the room it has
  const content = [path, position?.index, position?.count, back?.label, !!layout, !!accessory, t("Unified"), t("Split"), t("Ask AI…")].join("|");
  useLayoutEffect(() => {
    const element = row.current;
    if (!element) return;
    const observer = new ResizeObserver(() => setWidth(element.clientWidth));
    observer.observe(element); setWidth(element.clientWidth);
    return () => observer.disconnect();
  }, []);
  // The widest form that fits: start over when the room or the content changes, then fold one step at a time
  useLayoutEffect(() => {
    const element = row.current;
    if (!element) return;
    const key = `${width}|${content}`;
    if (measured.current !== key) { measured.current = key; if (level !== 0) { setLevel(0); return; } }
    if (level < folds.length - 1 && element.scrollWidth > element.clientWidth) setLevel(level + 1);
  });
  const menu = (): MenuItem[] => [
    // what the row had no room for comes first, in the row's order
    ...(position && !fold.position ? [
      { label: t("Previous file (K)"), disabled: position.index <= 0, onClick: () => position.step(-1) },
      { label: t("Next file (J)"), disabled: position.index >= position.count - 1, onClick: () => position.step(1) },
      "divider" as const,
    ] : []),
    ...(whitespace && !fold.whitespace ? [{ label: t("Hide whitespace"), checked: whitespace.hidden, onClick: () => whitespace.set(!whitespace.hidden) }] : []),
    ...(ask && !fold.ask ? [{ label: t("Ask AI…"), disabled: ask.disabled, onClick: ask.run }, "divider" as const] : []),
    ...more(),
  ];
  return (
    <header className="diff-header" data-fold={level}>
      <div className="diff-header-row" ref={row}>
        {back && <>
          <button type="button" className="diff-back status-tone" aria-keyshortcuts="Escape" data-tip={back.tip} onClick={back.onClick}><ChevronLeft size={12}/>{back.label}</button>
          <span className="diff-back-sep" aria-hidden="true"/>
        </>}
        {badge}
        <strong className={`diff-header-name ${fold.cut ? "cut" : ""}`} title={help ?? path}>{name}</strong>
        {fold.folder && <span className="diff-header-folder" title={folder}>{fold.folder}</span>}
        <span className="diff-header-space"/>
        {position && fold.position && <span className="diff-header-nav">
          <span className="diff-header-count mono">{position.index + 1} / {position.count}</span>
          <button type="button" className="diff-header-icon" disabled={position.index <= 0} aria-label={t("Previous file (K)")} aria-keyshortcuts="K" data-tip={t("Previous file (K)")} onClick={() => position.step(-1)}><ChevronUp size={13}/></button>
          <button type="button" className="diff-header-icon" disabled={position.index >= position.count - 1} aria-label={t("Next file (J)")} aria-keyshortcuts="J" data-tip={t("Next file (J)")} onClick={() => position.step(1)}><ChevronDown size={13}/></button>
        </span>}
        {accessory}
        {layout && <Segmented label={t("Diff layout")} value={layout.split && !layout.disabledReason ? "split" : "unified"} onChange={(value) => layout.set(value === "split")}
          options={[{ value: "unified", label: t("Unified") }, { value: "split", label: t("Split"), disabledReason: layout.disabledReason }]}/>}
        {whitespace && fold.whitespace && <button type="button" className={`diff-header-icon ${whitespace.hidden ? "on" : ""}`} aria-pressed={whitespace.hidden} aria-label={t("Hide whitespace")} data-tip={t("Hide whitespace")} onClick={() => whitespace.set(!whitespace.hidden)}><Pilcrow size={13}/></button>}
        {ask && fold.ask && <button type="button" className="diff-header-text" disabled={ask.disabled} data-tip={t("Ask questions about the selected changes")} onClick={ask.run}>{t("Ask AI…")}</button>}
        <button type="button" className="diff-header-icon diff-header-more" aria-label={t("More file actions")} aria-haspopup="menu" data-tip={t("More file actions")} onClick={(event) => showMenuBelow(event.currentTarget, menu())}><MoreHorizontal size={13}/></button>
      </div>
    </header>
  );
}
