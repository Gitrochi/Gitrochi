import { createElement } from "react";
import { createRoot } from "react-dom/client";
import type { Branch, Worktree } from "@/entities/git";
import { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { Sidebar } from "@/widgets/sidebar";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 30));
async function until(test: () => boolean) {
  const end = Date.now() + 2500;
  while (Date.now() < end) { if (test()) return true; await pause(); }
  return false;
}

/** Measure the production branch tree and worktree rows and exercise the disclosures without opening a repository. */
export async function sidebarTreeSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, subscribe: settings.subscribe, version: settings.getVersion };
  const memory = new Map<string, unknown>(), listeners = new Set<() => void>();
  let version = 0;
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:320px;height:740px;display:flex;flex-direction:column";
  document.body.append(host);
  const root = createRoot(host), store = new RepoStore();
  const longLeaf = "search-with-a-long-unbroken-branch-name-".repeat(8);
  const branch = (name: string, isRemote = false): Branch => ({ name, target: name, upstream: null, ahead: 0, behind: 0, upstreamGone: false, isCurrent: name === "feature/checkout", isRemote });
  const worktree = (path: string, name: string): Worktree => ({ path, head: "0000000", branch: name, isMain: name === "feature/checkout", locked: false, prunable: false });
  const revealed: string[] = [];
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const group = (id: string) => host.querySelector<HTMLElement>(`[data-tree-id="${id}"]`);
  const toggle = (id: string) => group(id)?.querySelector<HTMLButtonElement>(":scope > .side-tree-toggle");
  const label = (container: HTMLElement | null | undefined, text: string) => [...(container?.querySelectorAll<HTMLElement>(".side-tree-label") ?? [])].find((element) => element.textContent === text)!;
  const row = (element: HTMLElement) => element.closest<HTMLElement>(".side-tree-row")!;
  const left = (element: HTMLElement, selector: string) => row(element).querySelector<HTMLElement>(selector)!.getBoundingClientRect().left;
  const near = (a: number, b: number) => Math.abs(a - b) <= 1;
  const widths: { width: number; rows: number; nestedOffset: number; longLabelWidth: number; worktreeRows: number }[] = [];
  try {
    // Keep fixture expansion and sidebar preferences out of the user's settings.
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    settings.set = (key, value) => { memory.set(key, value); version++; listeners.forEach((listener) => listener()); };
    settings.subscribe = (listener) => { listeners.add(listener); return () => { listeners.delete(listener); }; };
    settings.getVersion = () => version;
    store.path = "C:/fixture/shop-web";
    store.headBranch = "feature/checkout";
    store.localBranches = [branch("main"), branch("feature/checkout"), branch("feature/search")];
    store.remoteBranches = [branch("origin/main", true), branch("origin/feature/checkout", true), branch(`origin/feature/${longLeaf}`, true), branch("upstream/main", true)];
    store.worktrees = [worktree("C:/fixture/shop-web", "feature/checkout"), worktree("C:/fixture/shop-web-search", "feature/search")];
    store.reveal = (target) => { revealed.push(target); };
    root.render(createElement(Sidebar, { store, openSettings: () => {} }));
    ensure(await until(() => !!toggle("r:origin") && !!label(group("l:feature")!, "checkout")), "The current local folder did not expand when the sidebar mounted");
    const origin = toggle("r:origin")!;
    ensure(origin instanceof HTMLButtonElement && origin.type === "button" && origin.tabIndex === 0 && origin.getAttribute("aria-expanded") === "false", "A collapsed remote must expose a focusable native disclosure button");
    origin.focus();
    ensure(document.activeElement === origin, "The remote disclosure could not receive keyboard focus");
    origin.click();
    ensure(await until(() => !!toggle("r:origin/feature")), "Expanding the remote did not reveal its folder");
    toggle("r:origin/feature")!.click();
    ensure(await until(() => !!label(group("r:origin/feature")!, longLeaf)), "Expanding the remote folder did not reveal its branches");
    ensure(origin.getAttribute("aria-expanded") === "true" && toggle("r:origin/feature")!.getAttribute("aria-expanded") === "true", "Expanded disclosure state was not exposed");
    ensure(origin.textContent?.trim().endsWith("3") && toggle("r:origin/feature")!.textContent?.trim().endsWith("2"), "The remote and folder branch counts were lost");
    for (const width of [280, 320]) {
      host.style.width = `${width}px`;
      await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
      const localSection = host.querySelector<HTMLElement>('[data-section="local"]')!;
      const localMain = label(localSection, "main"), localFolder = label(toggle("l:feature")!, "feature");
      const remoteRoot = label(origin, "origin"), remoteMain = label(group("r:origin")!, "main");
      const remoteFolder = label(toggle("r:origin/feature")!, "feature"), nested = label(group("r:origin/feature")!, longLeaf);
      for (const selector of [".lead", ".side-tree-label"]) {
        ensure(near(left(localMain, selector), left(localFolder, selector)), `Local folder and branch columns differ at ${width}px`);
        ensure(near(left(remoteMain, selector), left(remoteFolder, selector)), `Remote folder and branch columns differ at ${width}px`);
        ensure(near(left(remoteMain, selector) - left(remoteRoot, selector), 18), `Remote children did not move one level at ${width}px`);
        ensure(near(left(nested, selector) - left(remoteFolder, selector), 18), `Folder leaves did not move one level at ${width}px`);
      }
      // Worktree rows share the branch columns but keep their two-line layout (macOS: WorktreeRow).
      const worktreeRows = [...host.querySelectorAll<HTMLElement>('[data-section="worktrees"] .side-tree-row')];
      ensure(worktreeRows.length === 2, `The worktree rows are missing at ${width}px`);
      for (const element of worktreeRows) {
        ensure(near(element.querySelector<HTMLElement>(".lead")!.getBoundingClientRect().left, left(localMain, ".lead")), `Worktree and branch icons differ at ${width}px`);
        ensure(near(element.querySelector<HTMLElement>(".col")!.getBoundingClientRect().left, left(localMain, ".side-tree-label")), `Worktree and branch labels differ at ${width}px`);
        ensure(element.getBoundingClientRect().height >= 26 - 1, `A worktree row is shorter than a branch row at ${width}px`);
      }
      const rows = [...host.querySelectorAll<HTMLElement>(".side-tree-row")], bounds = host.getBoundingClientRect();
      ensure(rows.filter((element) => !worktreeRows.includes(element)).every((element) => near(element.getBoundingClientRect().height, 26)), `Tree row heights differ at ${width}px`);
      ensure(near(row(remoteFolder).getBoundingClientRect().top - row(remoteMain).getBoundingClientRect().top, 26), `Extra spacing separates sibling rows at ${width}px`);
      ensure(rows.every((element) => { const rect = element.getBoundingClientRect(); return rect.left >= bounds.left - 1 && rect.right <= bounds.right + 1; }), `A tree row overflowed the ${width}px sidebar`);
      ensure(nested.getBoundingClientRect().width > 0 && nested.scrollWidth > nested.clientWidth && getComputedStyle(nested).textOverflow === "ellipsis", `The long branch label did not truncate at ${width}px`);
      ensure(row(nested).dataset.tip?.includes(`origin/feature/${longLeaf}`), "The full long branch name is unavailable on hover");
      row(nested).click();
      ensure(revealed.at(-1) === `origin/feature/${longLeaf}`, "Clicking a nested branch did not reveal its commit");
      widths.push({ width, rows: rows.length, nestedOffset: left(nested, ".lead") - left(remoteFolder, ".lead"), longLabelWidth: nested.getBoundingClientRect().width, worktreeRows: worktreeRows.length });
    }
    toggle("r:origin/feature")!.click();
    ensure(await until(() => toggle("r:origin/feature")?.getAttribute("aria-expanded") === "false" && !label(group("r:origin/feature")!, longLeaf)), "Collapsing the folder left its branches visible");
    ensure(!!label(group("r:origin")!, "main"), "Collapsing a folder also hid its sibling branch");
    toggle("r:origin/feature")!.click();
    ensure(await until(() => !!label(group("r:origin/feature")!, longLeaf)), "The folder did not reopen");
    origin.click();
    ensure(await until(() => origin.getAttribute("aria-expanded") === "false" && !group("r:origin/feature")), "Collapsing the remote left child folders visible");
    origin.click();
    ensure(await until(() => !!label(group("r:origin/feature")!, longLeaf)), "Reopening the remote lost its nested expansion state");
    return [true, JSON.stringify({ widths, disclosureFocus: true, collapseAndReopen: true, retainedNestedExpansion: true, revealed: revealed.length })];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally {
    root.unmount(); host.remove();
    settings.get = original.get; settings.set = original.set; settings.subscribe = original.subscribe; settings.getVersion = original.version;
  }
}
