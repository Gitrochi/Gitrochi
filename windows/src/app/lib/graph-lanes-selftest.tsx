import { createRoot } from "react-dom/client";
import type { GraphEntry } from "@/entities/git";
import { RepoStore } from "@/entities/repo";
import { GraphView } from "@/widgets/commit-graph";

const pause = (ms = 60) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** A fixture graph with one commit per lane; nothing runs or loads (the e-mails have no avatar lookup). */
export function laneFixture(lanes: number): RepoStore {
  const store = new RepoStore();
  store.path = "C:/fixture/graph-lanes";
  const entries: GraphEntry[] = Array.from({ length: lanes }, (_, i) => ({
    commit: { id: String(i).padStart(40, "a"), parents: [], author: `Author ${i}`, email: `lane-${i}`, date: 1_700_000_000 - i * 3600, subject: `Lane ${i}` },
    row: { column: i, color: i % 8, segments: [], width: i + 1 },
  }));
  store.entries = entries; store.maxLanes = lanes;
  entries.forEach((e, i) => store.commitIndex.set(e.commit.id, i));
  return store;
}

/** Many lanes: the graph header gets a scrollbar, sideways scrolling moves every row, and a selected node is scrolled into view. */
export async function graphLanesSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div"); host.style.cssText = "position:fixed;left:-10000px;top:0;width:1100px;height:520px;display:flex"; document.body.append(host);
  const root = createRoot(host);
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const shifts = () => [...host.querySelectorAll<HTMLElement>(".commit-row .lane-shift")].map((s) => -parseFloat(s.style.marginLeft || "0"));
  try {
    const store = laneFixture(30);
    root.render(<GraphView store={store} />); await pause(); await pause();
    const cell = host.querySelector<HTMLElement>(".graph-header .graph-head-cell")!;
    const bar = cell.querySelector<HTMLElement>(".lane-scrollbar"), thumb = bar?.querySelector<HTMLElement>(".lane-scrollbar-thumb");
    ensure(bar && thumb && thumb.offsetWidth < bar.offsetWidth, "Thirty lanes must give the graph header a scrollbar with a partial thumb");
    ensure(shifts().every((s) => s === 0) && host.querySelector(".graph-cell.fade-right") && !host.querySelector(".graph-cell.fade-left"), "The lanes must start at the left with the right edge faded");
    cell.dispatchEvent(new WheelEvent("wheel", { deltaX: 120, bubbles: true, cancelable: true })); await pause();
    const moved = shifts();
    ensure(moved[0] === 120 && moved.every((s) => s === moved[0]) && host.querySelector(".graph-cell.fade-left"), `A sideways wheel must move every row's lanes together: ${moved.slice(0, 3)}`);
    cell.dispatchEvent(new WheelEvent("wheel", { deltaY: 60, shiftKey: true, bubbles: true, cancelable: true })); await pause();
    ensure(shifts()[0] === 180, "Shift+wheel must scroll the lanes too");
    cell.dispatchEvent(new WheelEvent("wheel", { deltaY: 60, bubbles: true, cancelable: true })); await pause();
    ensure(shifts()[0] === 180, "A plain vertical wheel over the header must not move the lanes");
    // set the selection directly: selecting through the store would also read commit details with git
    const choose = (i: number) => { store.selection = { kind: "commit", sha: store.entries[i].commit.id }; store.changed(); };
    choose(0); await pause();
    ensure(shifts()[0] === 0, "Selecting a commit on the first lane must scroll back to it");
    choose(29); await pause();
    const width = host.querySelector<HTMLElement>(".commit-row .graph-cell")!.offsetWidth, offset = shifts()[0], node = 6 + 22 * 29.5 - offset;
    ensure(offset > 0 && node > 0 && node < width, `Selecting the last lane must reveal its node: offset ${offset}, node at ${node} of ${width}`);
    store.entries = store.entries.slice(0, 4); store.maxLanes = 4; store.changed(); await pause();
    ensure(!host.querySelector(".lane-scrollbar") && shifts().every((s) => s === 0), "With fewer lanes the scrollbar must go and the offset reset");
    return [true, "Scrollbar with a partial thumb, sideways and Shift+wheel move every row, plain wheel does not, selection reveals the first and last lanes, fewer lanes reset the offset"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); }
}
