import { createRoot } from "react-dom/client";
import { RepoPage } from "@/pages/repo";
import { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const until = async (test: () => boolean) => {
  const end = Date.now() + 2500;
  while (Date.now() < end) { if (test()) return true; await pause(20); }
  return false;
};

/** 1000개 변경으로 진입한 뒤 마지막 파일 선택·트리 전환까지 실제 화면에서 확인한다. */
export async function changesPerformanceSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, run: ipc.run, http: ipc.http };
  const memory = new Map<string, unknown>([["avatarFetch", false], ["fileViewMode", "list"]]);
  const unexpected: string[] = [], opened: string[] = [];
  const store = new RepoStore();
  const host = document.createElement("div");
  Object.assign(host.style, { position: "fixed", left: "-10000px", top: "0", width: "1440px", height: "1000px", visibility: "hidden" });
  document.body.append(host);
  const root = createRoot(host);
  try {
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    settings.set = (key, value) => { memory.set(key, value); store.changed(); };
    ipc.run = async () => { unexpected.push("process"); throw new Error("Fixture blocked process"); };
    ipc.http = async () => { unexpected.push("network"); throw new Error("Fixture blocked network"); };
    store.path = "C:/gitrochi-large-changes-fixture";
    store.status = { branch: "fixture", upstream: null, ahead: 0, behind: 0, staged: [], conflicted: [], unstaged: Array.from({ length: 1000 }, (_, index) => ({ path: `src/folder-${Math.floor(index / 20)}/untracked-${String(index).padStart(4, "0")}.tsx`, oldPath: null, staged: false, kind: "untracked" })) };
    (store as unknown as { loadDiff(keepCurrent: boolean): void }).loadDiff = () => { if (store.diffSource?.kind === "working") opened.push(store.diffSource.change.path); store.changed(); };
    store.navigate("repository", false);
    root.render(<RepoPage store={store} openSettings={() => { unexpected.push("settings"); }} />);
    if (!await until(() => !!host.querySelector(".repository-screen > .inspector"))) return [false, "Repository screen did not mount"];
    // the uncommitted changes are the inspector column of the repository screen
    const started = performance.now(); store.select({ kind: "wip" });
    if (!await until(() => !!host.querySelector(".repository-screen > .inspector .file-list-virtual"))) return [false, "Large Changes list did not mount"];
    const elapsed = performance.now() - started;
    const initialRows = host.querySelectorAll(".repository-screen > .inspector .file-row").length;
    const panel = host.querySelector<HTMLElement>(".repository-screen > .inspector .file-list-virtual")!.closest<HTMLElement>(".shared-pane")!;
    const last = store.status.unstaged.at(-1)!.path;
    panel.scrollTop = panel.scrollHeight; panel.dispatchEvent(new Event("scroll"));
    const lastRow = () => [...host.querySelectorAll<HTMLElement>(".repository-screen > .inspector .file-row")].find((row) => row.dataset.tip === last);
    if (!await until(() => !!lastRow())) return [false, "Last file could not be reached by scrolling"];
    lastRow()!.click();
    if (!await until(() => opened.at(-1) === last)) return [false, "Last file opened the wrong diff"];
    panel.scrollTop = 0; panel.dispatchEvent(new Event("scroll"));
    const tree = [...host.querySelectorAll<HTMLButtonElement>(".repository-screen > .inspector button")].find((button) => button.dataset.tip === t("Show as folder tree"));
    if (!tree) return [false, "Tree toggle did not mount"];
    tree.click();
    if (!await until(() => host.querySelector(".repository-screen > .inspector .file-list-virtual")?.getAttribute("data-total-rows") === "1051")) return [false, "Tree rows did not preserve every file"];
    const treeRows = host.querySelectorAll(".repository-screen > .inspector .file-row").length;
    const firstFolder = [...host.querySelectorAll<HTMLElement>(".repository-screen > .inspector .file-row")].find((row) => row.querySelector(".ellipsis")?.textContent === "folder-0")!;
    firstFolder.click();
    if (!await until(() => host.querySelector(".repository-screen > .inspector .file-list-virtual")?.getAttribute("data-total-rows") === "1031")) return [false, "Virtual folder could not be collapsed"];
    store.status = { ...store.status, staged: Array.from({ length: 200 }, (_, index) => ({ path: `staged/ready-${index}.tsx`, oldPath: null, staged: true, kind: "modified" })) };
    store.changed();
    const panes = () => [...host.querySelectorAll<HTMLElement>(".repository-screen > .inspector .shared-pane")];
    if (!await until(() => panes().length === 2 && panes().every((pane) => pane.clientHeight >= 96 && pane.scrollHeight > pane.clientHeight) && Math.abs(panes()[0].clientHeight - panes()[1].clientHeight) <= 1))
      return [false, "Long staged and unstaged lists did not share the available height: " + JSON.stringify(panes().map((pane) => ({ height: pane.clientHeight, scroll: pane.scrollHeight })))];
    const sharedHeights = panes().map((pane) => pane.clientHeight);
    const ok = initialRows > 0 && initialRows < 100 && treeRows > 0 && treeRows < 100 && opened.length === 1 && unexpected.length === 0;
    return [ok, JSON.stringify({ files: 1000, initialRows, treeRows, elapsedMs: Math.round(elapsed), lastFileOpened: opened.at(-1) === last, folderCollapsed: true, sharedHeights, unexpected })];
  } finally {
    root.unmount(); await pause(20); host.remove();
    settings.get = original.get; settings.set = original.set; ipc.run = original.run; ipc.http = original.http;
  }
}
