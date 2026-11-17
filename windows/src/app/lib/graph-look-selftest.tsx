import { createRoot } from "react-dom/client";
import { emptyStatus, type GraphEntry, type RefLabel, rowSelection, wipCommit } from "@/entities/git";
import { t } from "@/shared/i18n";
import { RepoStore } from "@/entities/repo";
import { laneColors, peoplePalette } from "@/shared/lib";
import { Avatar } from "@/shared/ui";
import { GraphView } from "@/widgets/commit-graph";

const pause = (ms = 60) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const sha = (i: number) => String(i).padStart(40, "b");
const line = (x1: number, y1: number, x2: number, y2: number, color: number, dashed = false): GraphEntry["row"]["segments"][number] =>({ x1, y1, x2, y2, color, dashed });

/**
 * A fixture graph on two lanes: uncommitted changes, the checked-out branch with two unpushed commits, a branch on the remote only, a merge under a local
 * branch that is behind, and a tag. Nothing runs or loads (the e-mails have no avatar lookup).
 */
export function lookFixture(): RepoStore {
  const store = new RepoStore();
  store.path = "C:/fixture/graph-look";
  const commit = (i: number, subject: string, parents: number[], body?: string) => ({ id: sha(i), parents: parents.map(sha), author: `Author ${i % 3}`, email: `look-${i % 3}`, date: 1_700_000_000 - i * 3600, subject, body });
  const entries: GraphEntry[] = [
    { commit: wipCommit(sha(1)), row: { column: 1, color: 2, segments: [line(1, 0.5, 1, 1, 2, true)], width: 2 } },
    { commit: commit(1, "Restore the result list scroll position", [3]), row: { column: 1, color: 2, segments: [line(1, 0, 1, 0.5, 2, true), line(1, 0.5, 1, 1, 2)], width: 2 } },
    { commit: commit(2, "Show release assets in upload order", [4], "Keeps the order the uploads finished in"), row: { column: 0, color: 0, segments: [line(0, 0.5, 0, 1, 0), line(1, 0, 1, 1, 2)], width: 2 } },
    { commit: commit(3, "Keep the query when switching windows", [4]), row: { column: 1, color: 2, segments: [line(0, 0, 0, 1, 0), line(1, 0, 1, 0.5, 2), line(1, 0.5, 0, 1, 2)], width: 2 } },
    { commit: commit(4, "Merge pull request #52: Bump the Markdown renderer", [5, 6]), row: { column: 0, color: 0, segments: [line(0, 0, 0, 1, 0)], width: 1 } },
    { commit: commit(5, "Release 1.10.0", []), row: { column: 0, color: 0, segments: [line(0, 0, 0, 0.5, 0)], width: 1 } },
  ];
  store.entries = entries; store.maxLanes = 2; store.headHash = sha(1);
  entries.forEach((e, i) => store.commitIndex.set(e.commit.id, i));
  const refs: [number, RefLabel[]][] = [
    [1, [{ name: "feature/workspace-search", kind: "local", isCurrent: true, behind: 2 }]],
    [2, [{ name: "origin/main", kind: "remote", isCurrent: false }, { name: "origin/fix/terminal-focus", kind: "remote", isCurrent: false }]],
    [4, [{ name: "main", kind: "local", isCurrent: false, behind: 5 }]],
    [5, [{ name: "v1.10.0", kind: "tag", isCurrent: false }]],
  ];
  refs.forEach(([i, labels]) => store.refsByCommit.set(sha(i), labels));
  // the checked-out branch is two commits ahead of the server, as on the board
  store.unpushedCommits = new Set([sha(1), sha(3)]);
  store.status = { ...emptyStatus(), unstaged: ["a.ts", "b.ts", "c.ts"].map((path) => ({ path, oldPath: null, kind: "modified" as const, staged: false })) };
  return store;
}

/**
 * The graph's look on the redesign board: 32px rows with a 24 band, a 210 branch column, a 34 header in regular text with 24px menus,
 * 18px chips with radius 6 and a full lane border, the behind count on a branch that is not checked out, a neutral uncommitted row,
 * the shared empty state, and the fixed palettes: lane lines, tints and bands, an initial in the author's node colour, the white gap
 * where that colour is too close to its lane, and the HEAD ring in the accent.
 */
export async function graphLookSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div"); host.style.cssText = "position:fixed;left:-10000px;top:0;width:1100px;height:520px;display:flex"; document.body.append(host);
  const root = createRoot(host);
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const q = (selector: string, within: ParentNode = host) => within.querySelector<HTMLElement>(selector);
  const css = (el: Element | null | undefined) => getComputedStyle(el ?? host);
  const same = (a: string, b: string) => a.replace(/\s/g, "") === b.replace(/\s/g, "");
  // a palette value (a CSS variable or a mix of one) as the theme resolves it
  const resolve = (value: string) => {
    const probe = document.createElement("span"); probe.style.background = value; host.append(probe);
    const color = css(probe).backgroundColor; probe.remove(); return color;
  };
  try {
    const store = lookFixture();
    root.render(<GraphView store={store} />); await pause(); await pause();
    const header = q(".graph-header")!, rows = [...host.querySelectorAll<HTMLElement>(".commit-row")];
    ensure(header.offsetHeight === 35 && css(header).fontSize === "12px" && css(header).fontWeight === "400", `The header must be 34 and its divider, in 12px regular text: ${header.offsetHeight} ${css(header).fontSize} ${css(header).fontWeight}`);
    ensure((q(".head-ref .col-resizer")?.offsetHeight ?? 0) >= 30 && (q(".graph-head-message .col-resizer")?.offsetHeight ?? 0) >= 30, `The column edges' handles must be as tall as the header, so their lines show: ${q(".head-ref .col-resizer")?.offsetHeight}`);
    const tools = [...header.querySelectorAll<HTMLElement>(".graph-head-tools .icon-btn")];
    ensure(tools.length === 2 && tools.every((b) => b.offsetWidth === 24 && b.offsetHeight === 24 && b.querySelector("svg")?.getAttribute("width") === "14"), `The header's menus must be 24px targets with 14px icons: ${tools.map((b) => b.offsetWidth)}`);
    ensure(rows.length === 6 && rows.every((r) => r.offsetHeight === 32) && rows[1].offsetTop - rows[0].offsetTop === 32 && css(rows[1]).fontSize === "13px", `Rows must be 32 high and apart, in 13px text: ${rows[0]?.offsetHeight} ${rows[1]?.offsetTop} ${css(rows[1]).fontSize}`);
    ensure(q(".ref-col", rows[1])?.offsetWidth === 210 && q(".head-ref")?.offsetWidth === 210, `The branch column must be 210: ${q(".ref-col", rows[1])?.offsetWidth}`);
    ensure(q(".lane-band", rows[1])?.offsetHeight === 24 && q(".row-tail", rows[1])?.offsetHeight === 24 && q(".avatar-node", rows[1])?.offsetWidth === 18, `The band and the message must be 24 and the photo 18: ${q(".lane-band", rows[1])?.offsetHeight} ${q(".avatar-node", rows[1])?.offsetWidth}`);
    // the message starts under its header label
    const label = q(".graph-head-message .graph-head-label")!.getBoundingClientRect().left, subject = q(".msg-subject", rows[1])!.getBoundingClientRect().left;
    ensure(Math.abs(label - subject) <= 1, `The message must start under its header label: ${label} ${subject}`);
    // chips
    const current = q(".ref-pill", rows[1])!, remote = q(".ref-pill", rows[2])!, behind = q(".ref-pill", rows[4])!, tag = q(".ref-pill", rows[5])!;
    for (const chip of [current, remote, behind, tag]) {
      const style = css(chip);
      ensure(chip.offsetHeight === 18 && style.borderTopLeftRadius === "6px" && style.fontSize === "11px" && style.fontWeight === "600" && style.borderTopWidth === "1px", `A chip must be 18 high with radius 6, 11px semibold and a 1px border: ${chip.textContent} ${chip.offsetHeight} ${style.borderTopLeftRadius} ${style.fontWeight}`);
    }
    ensure(current.classList.contains("solid") && same(css(current).backgroundColor, resolve(laneColors(2).line)) && same(css(current).color, resolve(laneColors(2).onLine)) && !current.textContent?.includes("↓"), `The checked-out branch must be filled with its lane colour, without a behind count: ${css(current).backgroundColor} ${current.textContent}`);
    ensure(same(css(remote).borderTopColor, resolve(laneColors(0).line)) && same(css(remote).color, resolve(laneColors(0).line)) && same(css(remote).backgroundColor, resolve(laneColors(0).tint)), `Another branch must be its lane colour on the lane's tint inside a full-colour border: ${css(remote).borderTopColor} ${css(remote).backgroundColor}`);
    ensure(same(css(q(".ref-more", rows[2])).backgroundColor, resolve(laneColors(0).tint)) && same(q(".ref-line", rows[2])!.style.background, laneColors(0).line), "The +N chip must sit on the lane's tint and the connector be the lane's line");
    ensure(q(".ref-more", rows[2])?.textContent === "+1" && q(".ref-more", rows[2])?.offsetHeight === 18, `More refs on a commit must fold into a +N chip: ${q(".ref-more", rows[2])?.textContent}`);
    ensure(q(".ref-behind", behind)?.textContent === "↓5", `A branch that is not checked out must show how far it is behind: ${behind.textContent}`);
    // the uncommitted row and the tag chip are neutral: a probe resolves the theme's grey
    const probe = document.createElement("span"); probe.style.cssText = "background:var(--graph-neutral)"; rows[0].append(probe);
    const neutral = css(probe).backgroundColor; probe.remove();
    ensure(tag.classList.contains("tag") && css(tag).borderTopColor === neutral, `A tag chip must have the neutral border: ${css(tag).borderTopColor} ${neutral}`);
    const wipStrokes = [...rows[0].querySelectorAll("svg path, svg circle")].map((el) => el.getAttribute("stroke")).filter(Boolean);
    ensure(!q(".lane-band", rows[0]) && css(q(".msg-bar", rows[0])).backgroundColor === neutral && wipStrokes.length === 2 && wipStrokes.every((stroke) => stroke === "var(--graph-neutral)"),
      `The uncommitted row must have no band and a neutral bar, node and line: ${css(q(".msg-bar", rows[0])).backgroundColor} ${wipStrokes}`);
    const files = q(".wip-chip", rows[0])!;
    ensure(files.classList.contains("status-pill") && files.offsetHeight === 18 && !same(css(files).backgroundColor, resolve(laneColors(2).line)), `The "N files" pill must be a neutral pill: ${files.offsetHeight} ${css(files).backgroundColor}`);
    const local = q(".unpushed-chip", rows[1]);
    ensure(local?.textContent === t("local") && local.classList.contains("status-pill") && local.offsetHeight === 18 && same(css(local).backgroundColor, css(files).backgroundColor)
      && local.getBoundingClientRect().left > q(".msg-subject", rows[1])!.getBoundingClientRect().right && q(".unpushed-chip", rows[3]) && !q(".unpushed-chip", rows[2]) && !q(".unpushed-chip", rows[0]),
      `An unpushed commit must have the neutral "local" pill after its message, and only those: ${local?.textContent} ${local?.offsetHeight} ${css(local).backgroundColor}`);
    ensure(rows[1].querySelector('svg path[stroke="var(--graph-neutral)"]') && same(q(".msg-bar", rows[1])!.style.background, laneColors(2).line), "The dashed line must reach the parent's node in grey, and a commit's bar must be its lane colour");
    // the palettes: lines and bands from the lane table, the HEAD ring in the accent, an initial in the author's node colour
    ensure(rows[2].querySelector(`svg path[stroke="${laneColors(2).line}"]`) && rows[2].querySelector(`svg path[stroke="${laneColors(0).line}"]`), "Each lane's line must be drawn in its own colour");
    ensure(same(css(q(".lane-band", rows[1])).backgroundColor, resolve(laneColors(2).tint)), `An unselected commit's band must be its lane's tint: ${css(q(".lane-band", rows[1])).backgroundColor}`);
    const ring = rows[1].querySelector('svg circle[stroke="var(--accent)"]');
    ensure(ring?.getAttribute("r") === "14" && ring.getAttribute("stroke-width") === "2" && !rows[2].querySelector('svg circle[stroke="var(--accent)"]'), "Only the HEAD node must have the 2px accent ring, 2px clear of it");
    const initial = q(".avatar-node .avatar", rows[1])!;
    ensure(initial.textContent === "A" && same(css(initial).backgroundColor, resolve(peoplePalette[0].node)) && same(css(initial).color, "rgb(255, 255, 255)") && css(initial).fontSize === "11px" && !initial.dataset.gap,
      `An author without a photo must be an 11px white initial on their node colour: ${css(initial).backgroundColor} ${css(initial).color} ${css(initial).fontSize}`);
    // set the selection directly: selecting through the store would also read commit details with git
    store.selection = rowSelection(store.entries[1].commit); store.changed(); await pause();
    ensure(same(css(q(".lane-band", rows[1])).backgroundColor, resolve(laneColors(2).selected)), `The selected commit's band must be its lane colour at 40%: ${css(q(".lane-band", rows[1])).backgroundColor}`);
    store.selection = null; store.changed(); await pause();
    // the white gap: Sam's green on the teal lane, and none on the blue one
    const gaps = document.createElement("div"); host.append(gaps);
    const gapRoot = createRoot(gaps);
    gapRoot.render(<><Avatar name="Sam" email="look-2" size={18} lane={1} /><Avatar name="Sam" email="look-2" size={18} lane={0} /><Avatar name="Sam" email="look-2" size={20} /></>); await pause();
    const [close, apart, plain] = [...gaps.querySelectorAll<HTMLElement>(".avatar")];
    const dark = document.documentElement.dataset.theme === "dark";
    ensure(close?.dataset.gap === "light" && !apart?.dataset.gap && (dark ? css(close).boxShadow === "none" : css(close).boxShadow.includes(resolve("var(--surface)"))),
      `A node colour too close to its lane must keep a 2px surface gap in light: ${close?.dataset.gap} ${css(close).boxShadow}`);
    ensure(same(css(plain).backgroundColor, resolve(peoplePalette[1].fill)) && same(css(plain).color, resolve(peoplePalette[1].letter)), `An initial outside the graph must be the person's letter on their tint: ${css(plain).backgroundColor} ${css(plain).color}`);
    gapRoot.unmount(); gaps.remove();
    // no commits: the shared empty form with its one action
    store.entries = []; store.commitIndex.clear(); store.changed(); await pause();
    const empty = q(".graph-scroll .hosted-empty");
    ensure(empty && q(".hosted-empty-icon svg", empty)?.getAttribute("width") === "24" && css(q(".hosted-empty-title", empty)).fontSize === "15px" && empty.querySelectorAll("button").length === 1, "A repository without commits must show the shared empty state with one action");
    return [true, "34 header in regular text with 24px menus, 32 rows with a 24 band and 13px text, a 210 branch column, the message under its label, 18px chips with radius 6 and a full lane border on the lane's tint, the behind count on a branch that is not checked out, a neutral tag chip and uncommitted row, lane tints and the 40% selected band, an accent HEAD ring, initials in the people palette with the white gap, and the shared empty state"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); }
}
