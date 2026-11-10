import { FILE_ROW_HEIGHT, visibleFileRange } from "../lib/visible-file-range";
import { FolderOpen } from "@/shared/icons";
import { ChevronDown, ChevronRight, Folder } from "@/shared/icons";
import { type ReactNode, useLayoutEffect, useMemo, useRef, useState } from "react";
import { changeId, type FileChange, fileDir, fileName, type LineStat, StatusBadge, treeRows } from "@/entities/git";
import { t } from "@/shared/i18n";
import { IconButton, LineStatText, type MenuItem, showContextMenu, useFileViewMode } from "@/shared/ui";

/** 변경 파일 목록. 트리 모드에서는 폴더를 접고 펼 수 있고, 폴더 단위로 스테이지·언스테이지할 수 있다. */
export function ChangeList({
  changes,
  isSelected,
  stats = {},
  action,
  onOpen,
  menu,
  folderMenu,
}: {
  changes: FileChange[];
  isSelected: (c: FileChange) => boolean;
  stats?: Record<string, LineStat>;
  action?: { icon: ReactNode; tip: string; run: (files: FileChange[]) => void };
  onOpen: (c: FileChange) => void;
  menu: (c: FileChange) => MenuItem[];
  /** 트리의 폴더 줄 우클릭 메뉴(경로는 저장소 기준) */
  folderMenu?: (path: string) => MenuItem[];
}) {
  const mode = useFileViewMode();
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const indent = 14;

  const fileRow = (c: FileChange, showDir: boolean, pad = 0) => {
    const stat = stats[c.path];
    return (
      <div
        key={changeId(c)}
        className={`file-row ${isSelected(c) ? "selected" : ""}`}
        style={{ paddingLeft: 6 + pad }}
        onClick={() => onOpen(c)}
        onContextMenu={(e) => showContextMenu(e, menu(c))}
        data-tip={c.oldPath ? `${c.oldPath} → ${c.path}` : c.path}
      >
        <StatusBadge kind={c.kind} />
        <span className="ellipsis" style={{ flex: "0 1 auto" }}>
          {fileName(c.path)}
        </span>
        {(c.oldPath || showDir) && (
          <span className="ellipsis muted" style={{ fontSize: 11.5, direction: "rtl", textAlign: "left", flex: "1 1 0" }}>
            {c.oldPath ? `← ${showDir ? c.oldPath : fileName(c.oldPath)}` : fileDir(c.path)}
          </span>
        )}
        <span className="spacer" />
        {stat && (stat.added !== null && stat.deleted !== null ? <LineStatText added={stat.added} deleted={stat.deleted} /> : <span className="faint" style={{ fontSize: 11 }}>{t("Binary")}</span>)}
        {action && (
          <IconButton
            small
            className="act"
            icon={action.icon}
            tip={action.tip}
            onClick={(e) => {
              e.stopPropagation();
              action.run([c]);
            }}
          />
        )}
      </div>
    );
  };

  const rows = useMemo(() => mode === "tree" ? treeRows(changes, collapsed) : changes.map((change) => ({ id: changeId(change), kind: "file" as const, change, depth: 0 })), [changes, collapsed, mode]);

  const toggle = (p: string) => {
    const s = new Set(collapsed);
    if (s.has(p)) s.delete(p);
    else s.add(p);
    setCollapsed(s);
  };
  return (
    <VisibleFileRows rows={rows} render={(r) =>
        r.kind === "folder" ? (
          <div
            key={r.id}
            className="file-row"
            style={{ paddingLeft: 6 + r.depth * indent }}
            onClick={() => toggle(r.path)}
            onContextMenu={folderMenu ? (e) => showContextMenu(e, folderMenu(r.path)) : undefined}
          >
            <span className="muted" style={{ display: "inline-flex", width: 12 }}>
              {collapsed.has(r.path) ? <ChevronRight size={12} /> : <ChevronDown size={12} />}
            </span>
            <span style={{ color: "var(--accent)", display: "inline-flex" }}>{collapsed.has(r.path) ? <Folder size={14} /> : <FolderOpen size={14} />}</span>
            <span className="ellipsis">{r.name}</span>
            <span className="muted" style={{ fontSize: 11.5 }}>
              {r.files.length}
            </span>
            <span className="spacer" />
            {action && (
              <IconButton
                small
                className="act"
                icon={action.icon}
                tip={action.tip + t(" — whole folder")}
                onClick={(e) => {
                  e.stopPropagation();
                  action.run(r.files);
                }}
              />
            )}
          </div>
        ) : (
          fileRow(r.change, mode === "list", mode === "list" ? 0 : r.depth * indent + indent)
        )
      } />
  );
}


/** 전체 목록 높이는 유지하고 스크롤 근처의 행만 만들어 변경 화면 진입 비용을 제한한다. */
function VisibleFileRows<T extends { id: string }>({ rows, render }: { rows: T[]; render: (row: T) => ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const [range, setRange] = useState({ first: 0, last: 40 });
  const virtual = rows.length > 120;
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element || !virtual) return;
    let scroll = element.parentElement;
    while (scroll && !/(auto|scroll)/.test(getComputedStyle(scroll).overflowY)) scroll = scroll.parentElement;
    if (!scroll) return;
    const viewport = scroll;
    const update = () => {
      const offset = Math.max(0, viewport.getBoundingClientRect().top - element.getBoundingClientRect().top);
      const stack = viewport.closest<HTMLElement>(".shared-stack");
      const natural = !!stack && getComputedStyle(stack).overflowY === "visible";
      const { first, last } = visibleFileRange(rows.length, offset, viewport.clientHeight, document.documentElement.clientHeight || window.innerHeight, !natural);
      setRange((old) => old.first === first && old.last === last ? old : { first, last });
    };
    update();
    viewport.addEventListener("scroll", update, { passive: true });
    const observer = new ResizeObserver(update);
    observer.observe(viewport); observer.observe(element);
    return () => { viewport.removeEventListener("scroll", update); observer.disconnect(); };
  }, [virtual, rows.length]);
  if (!virtual) return <div className="col">{rows.map(render)}</div>;
  return <div ref={ref} className="file-list-virtual" style={{ height: rows.length * FILE_ROW_HEIGHT }} data-total-rows={rows.length}>
    {rows.slice(range.first, range.last).map((row, index) => <div key={row.id} className="file-list-virtual-row" style={{ top: (range.first + index) * FILE_ROW_HEIGHT, height: FILE_ROW_HEIGHT }}>{render(row)}</div>)}
  </div>;
}
