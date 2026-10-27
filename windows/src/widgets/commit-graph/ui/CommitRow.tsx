import { Check, Cloud, Crosshair, Laptop, Tag as TagIcon } from "lucide-react";
import { memo, useState } from "react";
import { commitMenu, refMenu } from "@/features/git-menus";
import { avatars } from "@/entities/avatar";
import { type CIPipeline, CIStatusIcon, statusInfo } from "@/entities/ci";
import { type GraphEntry, type GraphRow, isMerge, isPending, type RefLabel, rowSelection, short, wipWorktree } from "@/entities/git";
import { branchPayload, commitPayload, type RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { drag, laneColor, longDate, shortDate, useObserve } from "@/shared/lib";
import { Avatar, showContextMenu, tip } from "@/shared/ui";
import { AVATAR, type GraphColumns, LANE_W, LEFT_PAD, ROW_H } from "../lib/metrics";

export const CommitRow = memo(function CommitRow({
  store,
  entry,
  top,
  gw,
  laneOffset,
  refs,
  selected,
  isHead,
  wipCount,
  wipLabel,
  match,
  ci,
  cols,
}: {
  store: RepoStore;
  entry: GraphEntry;
  top: number;
  /** The width every lane needs; the graph column shows the part from laneOffset on */
  gw: number;
  /** How far the lanes are scrolled sideways (shared by every row) */
  laneOffset: number;
  /** 화면 너비에 맞춘 칸(좁으면 일부 칸을 숨기고 줄인다) */
  cols: GraphColumns;
  refs: RefLabel[] | undefined;
  selected: boolean;
  isHead: boolean;
  wipCount: number;
  /** Branch of another worktree's row */
  wipLabel?: string;
  match: 0 | 1 | 2;
  /** 이 커밋의 가장 최근 CI 파이프라인 */
  ci?: CIPipeline;
}) {
  const [dropOn, setDropOn] = useState(false);
  const c = entry.commit;
  const wip = isPending(c);
  const worktree = wipWorktree(c);
  const tint = laneColor(entry.row.color);
  const groups = groupRefs(refs ?? []);
  return (
    <div
      className={`commit-row ${selected ? "selected" : ""} ${match === 1 ? "hit" : match === 2 ? "miss" : ""} ${dropOn ? "drop" : ""}`}
      style={{ top, gap: 0 }}
      onMouseDown={() => store.select(rowSelection(c))}
      onDoubleClick={worktree !== null ? () => void store.switchWorktree(worktree) : undefined}
      onContextMenu={(e) => showContextMenu(e, commitMenu(store, c))}
      draggable={!wip}
      onDragStart={(e) => {
        drag.payload = commitPayload + c.id;
        e.dataTransfer.setData("text/plain", drag.payload);
        e.dataTransfer.effectAllowed = "move";
      }}
      onDragEnd={() => (drag.payload = null)}
      onDragOver={(e) => {
        if (!wip && drag.payload) {
          e.preventDefault();
          if (!dropOn) setDropOn(true);
        }
      }}
      onDragLeave={() => setDropOn(false)}
      onDrop={(e) => {
        e.preventDefault();
        setDropOn(false);
        const payload = e.dataTransfer.getData("text/plain") || drag.payload;
        drag.payload = null;
        if (payload) store.handleDrop(payload, entry);
      }}
    >
      {/* 왼쪽: 브랜치·태그(첫 번째 + 나머지 개수)와 그래프까지 이어지는 선 */}
      {cols.ref > 0 && (
        <div className="ref-col" style={{ width: cols.ref }}>
          {groups.length > 0 && (
            <>
              <RefPill store={store} group={groups[0]} tint={tint} />
              {groups.length > 1 && (
                <span
                  className="ref-more"
                  style={{ color: tint, background: `color-mix(in srgb, ${tint} 15%, transparent)` }}
                  data-tip={groups.slice(1).map((g) => g.name).join("\n")}
                  onContextMenu={(e) =>
                    showContextMenu(
                      e,
                      groups.slice(1).map((g) => ({ label: g.name, submenu: g.all.length > 1 ? g.all.map((r) => ({ label: r.name, submenu: refMenu(store, r) })) : refMenu(store, g.primary) })),
                    )
                  }
                >
                  +{groups.length - 1}
                </span>
              )}
              <span className="ref-line" style={{ background: tint }} />
            </>
          )}
        </div>
      )}
      {cols.graph > 0 && (
        <div
          className={`graph-cell${laneOffset > 0 ? " fade-left" : ""}${laneOffset < gw - cols.graph ? " fade-right" : ""}`}
          style={{ position: "relative", display: "flex", width: cols.graph, flex: "none", overflow: "hidden" }}
        >
          {/* like GitKraken: a band from the node to the message, a little shorter than the row so rows stay apart */}
          <span className="lane-band" style={{ left: Math.max(0, LEFT_PAD + LANE_W * (entry.row.column + 0.5) - laneOffset), background: `color-mix(in srgb, ${tint} ${selected ? 40 : 10}%, transparent)` }} />
          {/* the lanes move together with the header's scrollbar; the line from the labels follows the node */}
          <span className="lane-shift" style={{ marginLeft: -laneOffset }}>
            <GraphCell row={entry.row} width={gw} isWIP={wip} isHead={isHead} isMerge={isMerge(c)} hasRefs={groups.length > 0} author={c.author} email={c.email} />
          </span>
        </div>
      )}
      {/* 커밋 메시지: 레인 색 막대 · 제목 · 본문 첫 줄(흐리게) · 오른쪽 끝에 시간. 작성자·SHA 는 마우스를 올리면. */}
      <div className="msg" data-tip={wip ? undefined : `${c.author} <${c.email}>\n${longDate(c.date)} · ${short(c.id)}`}>
        <span className="msg-bar" style={{ background: tint, opacity: wip ? 0.5 : 0.9 }} />
        {wip ? (
          <>
            <i className="muted">{worktree !== null ? t("// Uncommitted changes in {0}", wipLabel ?? "") : t("// Uncommitted changes")}</i>
            <span className="wip-chip" style={{ background: `color-mix(in srgb, ${tint} 18%, transparent)` }}>
              {t("{0} files", wipCount)}
            </span>
          </>
        ) : (
          <>
            <span className="msg-subject" style={{ color: isMerge(c) ? "var(--text-2)" : undefined }}>
              {c.subject}
            </span>
            {ci && (
              <span
                className="ci-badge"
                data-tip={t("CI: {0} · {1}#{2} — click to open in Actions", statusInfo[ci.status].title, ci.name ? ci.name + " " : "", ci.number)}
                onMouseDown={(e) => e.stopPropagation()}
                onClick={() => store.openCI(ci)}
              >
                <CIStatusIcon status={ci.status} size={12} />
              </span>
            )}
            {c.body && (
              <span className="msg-body">
                <span>{c.body}</span>
              </span>
            )}
            {cols.time && <span className="msg-time">{shortDate(c.date)}</span>}
          </>
        )}
      </div>
    </div>
  );
});

/** 같은 이름의 로컬·원격 브랜치를 한 라벨로 묶은 것(💻 로컬, ☁ 원격) */
interface RefGroup {
  name: string;
  isCurrent: boolean;
  local: string | null;
  remotes: string[];
  isTag: boolean;
  isHead: boolean;
  primary: RefLabel;
  all: RefLabel[];
}

export function groupRefs(refs: RefLabel[]): RefGroup[] {
  const order: string[] = [];
  const by = new Map<string, { local: string | null; remotes: string[]; current: boolean }>();
  const heads: RefGroup[] = [];
  const tags: RefGroup[] = [];
  for (const r of refs) {
    if (r.kind === "head") {
      const l: RefLabel = { name: "HEAD", kind: "head", isCurrent: true };
      heads.push({ name: "HEAD", isCurrent: true, local: null, remotes: [], isTag: false, isHead: true, primary: l, all: [l] });
    } else if (r.kind === "tag") {
      tags.push({ name: r.name, isCurrent: false, local: null, remotes: [], isTag: true, isHead: false, primary: r, all: [r] });
    } else {
      const key = r.kind === "remote" ? r.name.slice(r.name.indexOf("/") + 1) : r.name;
      if (!by.has(key)) {
        order.push(key);
        by.set(key, { local: null, remotes: [], current: false });
      }
      const g = by.get(key)!;
      if (r.kind === "local") {
        g.local = r.name;
        g.current = r.isCurrent;
      } else g.remotes.push(r.name);
    }
  }
  const branches: RefGroup[] = order.map((name) => {
    const g = by.get(name)!;
    const all: RefLabel[] = [...(g.local ? [{ name: g.local, kind: "local" as const, isCurrent: g.current }] : []), ...g.remotes.map((n) => ({ name: n, kind: "remote" as const, isCurrent: false }))];
    return { name, isCurrent: g.current, local: g.local, remotes: g.remotes, isTag: false, isHead: false, primary: all[0], all };
  });
  const rank = (g: RefGroup) => (g.isCurrent ? 0 : g.local ? 1 : 2);
  branches.sort((a, b) => rank(a) - rank(b));
  return [...heads, ...branches, ...tags];
}

/** 브랜치 라벨: 더블클릭 체크아웃, 우클릭 메뉴, 끌어서 다른 브랜치에 놓기 */
function RefPill({ store, group, tint }: { store: RepoStore; group: RefGroup; tint: string }) {
  const branch = !group.isTag && !group.isHead;
  const color = group.isTag ? "#8e8e93" : group.isHead ? "var(--text)" : tint;
  const solid = group.isCurrent;
  const target = group.local ?? group.remotes[0] ?? group.name;
  const tipText = [
    group.local ? t("Local: {0}{1}", group.local, group.isCurrent ? t(" (current)") : "") : "",
    group.remotes.length ? t("Remote: {0}", group.remotes.join(", ")) : "",
    group.isTag ? t("Tag: {0}", group.name) : "",
    branch ? t("Double-click: check out · Drag onto another branch's row: merge or rebase · Right-click: menu") : "",
  ]
    .filter(Boolean)
    .join("\n");
  return (
    <span
      className={`ref-pill ${solid ? "solid" : ""}`}
      style={{
        color: solid ? "#fff" : color,
        background: solid ? color : `color-mix(in srgb, ${color} 18%, transparent)`,
        boxShadow: solid ? undefined : `inset 0 0 0 1px color-mix(in srgb, ${color} 50%, transparent)`,
      }}
      draggable={branch}
      onDragStart={(e) => {
        e.stopPropagation();
        drag.payload = branchPayload + target;
        e.dataTransfer.setData("text/plain", drag.payload);
        e.dataTransfer.effectAllowed = "move";
      }}
      onDragEnd={() => (drag.payload = null)}
      onDoubleClick={() => {
        const b = branch ? store.branchNamed(target) : null;
        if (b) void store.checkout(b);
      }}
      onContextMenu={(e) =>
        showContextMenu(e, group.all.length > 1 ? group.all.map((r) => ({ label: r.name, submenu: refMenu(store, r) })) : refMenu(store, group.primary))
      }
      data-tip={tip(group.name, tipText)}
    >
      {solid && <Check size={9} strokeWidth={3.5} />}
      {group.isTag && <TagIcon size={10} strokeWidth={2.5} />}
      {group.isHead && <Crosshair size={10} strokeWidth={2.5} />}
      <span className="name">{group.name}</span>
      {group.local && <Laptop size={10} strokeWidth={2.2} />}
      {group.remotes.length > 0 && <Cloud size={10} strokeWidth={2.2} />}
    </span>
  );
}

/** 커밋 동그라미: 작성자 프로필 사진(없으면 이니셜) */
function AvatarNode({ name, email, x }: { name: string; email: string; x: number }) {
  useObserve(avatars);
  const url = avatars.url(email, name);
  const ok = url && !avatars.failed.has(url);
  return (
    <span className="avatar-node" style={{ left: x - AVATAR / 2, top: (ROW_H - AVATAR) / 2 }} data-tip={name}>
      {ok ? (
        <img src={url} width={AVATAR} height={AVATAR} alt="" draggable={false} onError={() => avatars.markFailed(url)} />
      ) : (
        <Avatar name={name} email={email} size={AVATAR} />
      )}
    </span>
  );
}

/** 한 행의 그래프 조각: 위·아래로 이어지는 레인 선, 브랜치 라벨에서 오는 선, 커밋 동그라미 */
const GraphCell = memo(function GraphCell({
  row,
  width,
  isWIP,
  isHead,
  isMerge,
  hasRefs,
  author,
  email,
}: {
  row: GraphRow;
  width: number;
  isWIP: boolean;
  isHead: boolean;
  isMerge: boolean;
  hasRefs: boolean;
  author: string;
  email: string;
}) {
  const h = ROW_H;
  const x = (lane: number) => LEFT_PAD + LANE_W * (lane + 0.5);
  const color = laneColor(row.color);
  const cx = x(row.column),
    cy = h / 2;
  const avatarNode = !isWIP && !isMerge;
  return (
    <span style={{ position: "relative", width, height: h, flex: "none", display: "block" }}>
      <svg width={width} height={h} style={{ display: "block", overflow: "hidden" }}>
        {hasRefs && <line x1={0} y1={cy} x2={cx} y2={cy} stroke={color} strokeWidth={1.5} />}
        {row.segments.map((s, i) => {
          const ax = x(s.x1),
            ay = h * s.y1,
            bx = x(s.x2),
            by = h * s.y2;
          const mid = (ay + by) / 2;
          const d = s.x1 === s.x2 ? `M${ax},${ay}L${bx},${by}` : `M${ax},${ay}C${ax},${mid} ${bx},${mid} ${bx},${by}`;
          return <path key={i} d={d} fill="none" stroke={laneColor(s.color)} strokeWidth={2} strokeLinecap="round" strokeDasharray={s.dashed ? "3 3" : undefined} />;
        })}
        {isWIP ? (
          <circle cx={cx} cy={cy} r={7} fill="var(--surface)" stroke={color} strokeWidth={2} strokeDasharray="2.5 2" />
        ) : isMerge ? (
          <>
            <circle cx={cx} cy={cy} r={5.5} fill="var(--surface)" />
            <circle cx={cx} cy={cy} r={4} fill={color} />
          </>
        ) : (
          <circle cx={cx} cy={cy} r={AVATAR / 2 + 2} fill={color} />
        )}
        {isHead && <circle cx={cx} cy={cy} r={isMerge ? 8 : AVATAR / 2 + 5} fill="none" stroke={color} strokeWidth={1.5} />}
      </svg>
      {avatarNode && <AvatarNode name={author} email={email} x={cx} />}
    </span>
  );
});
