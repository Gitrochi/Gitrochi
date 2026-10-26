import { createRoot } from "react-dom/client";
import { parseConflict } from "@/entities/git";
import { RepoStore } from "@/entities/repo";
import { LocalWorkflowsSheet } from "@/features/local-workflows";
import { ConflictView } from "@/features/resolve-conflict";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 35));
/** 서버·저장소를 건드리지 않고 실제 화면의 네 탭과 세 열 충돌 선택을 조작한다. */
export async function localWorkflowsSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div"); host.hidden = true; document.body.append(host);
  let root = createRoot(host);
  const store = new RepoStore(), state = store.localWorkflows;
  const oid = "a".repeat(40);
  let previews = 0, tracks = 0, updates = 0, bisects = 0, saves = 0;
  const check = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const click = async (label: string) => { const button = [...host.querySelectorAll<HTMLButtonElement>("button")].find((entry) => entry.textContent?.trim() === t(label)); check(button && !button.disabled, `Missing enabled button: ${label}`); button!.click(); await pause(); };
  try {
    store.loadLocalWorkflows = async () => {};
    state.recovery = [{ id: "123-a", worktree: oid, index: oid, head: oid, created: "2026-01-01T00:00:00Z" }];
    state.lfsAvailable = true;
    state.submodules = [{ path: "vendor/library", sha: oid, status: "-", url: "https://example.com/library.git", configName: "library" }];
    store.previewRecovery = async () => { previews++; state.preview = "+saved fixture"; store.changed(); };
    store.lfsTrack = async () => { tracks++; };
    store.updateSubmodule = async () => { updates++; };
    store.startBisect = async () => { bisects++; };
    root.render(<LocalWorkflowsSheet store={store} close={() => {}} />); await pause();
    await click("Preview changes"); check(previews === 1 && host.querySelector("pre")?.textContent?.includes("saved fixture"), "Recovery preview was not rendered");
    await click("LFS"); check(host.textContent?.includes(t("Track pattern")), "LFS tracking UI missing");
    await click("Submodules"); await click("Initialize / update"); check(updates === 1, "Submodule action did not request the reviewed entry");
    await click("Bisect"); check(host.textContent?.includes(t("Start bisect")), "Bisect setup missing");
    check(tracks === 0 && bisects === 0, "An operation ran without user input");
    root.unmount(); host.replaceChildren(); root = createRoot(host);
    const change = { path: "source.txt", oldPath: null, kind: "conflicted" as const, staged: false };
    store.loadConflict = async () => { store.conflictPath = change.path; store.conflictDoc = parseConflict("before\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> topic\nafter\n"); store.changed(); };
    store.saveConflictResolution = async () => { saves++; };
    function ObservedConflict() { useObserve(store); return <ConflictView store={store} change={change} />; }
    root.render(<ObservedConflict />); await pause(); await pause();
    check(host.querySelectorAll("textarea").length === 3, "Three-way editor did not show three full-file panes");
    await click("Show common ancestor"); check(host.querySelectorAll("textarea").length === 4, "Common-ancestor pane missing");
    await click("Mine");
    check(host.querySelector<HTMLTextAreaElement>('textarea[aria-label="' + t("Final result") + '"]')?.value === "before\nmine\nafter\n", "Block selection did not update the final result");
    await click("Save and mark as resolved"); check(saves === 1, "Resolved result was not submitted");
    return [true, "Recovery preview, LFS controls, submodule action, bisect setup and three-way conflict/base/selection/save rendered"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); store.closeConflict(); }
}
