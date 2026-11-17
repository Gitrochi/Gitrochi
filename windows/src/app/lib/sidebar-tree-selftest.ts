import { createElement } from "react";
import { createRoot } from "react-dom/client";
import type { Branch, Worktree } from "@/entities/git";
import { branchPayload, RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { drag } from "@/shared/lib";
import { Sidebar } from "@/widgets/sidebar";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 30));
async function until(test: () => boolean) {
  const end = Date.now() + 2500;
  while (Date.now() < end) { if (test()) return true; await pause(); }
  return false;
}

/**
 * Measure the production Branches tab without opening a repository: the Filter branches field, the three sections
 * the board draws (and Stashes after them), their heads, counts and marks, the branch tree and its disclosures, and
 * what the field does to them.
 */
export async function sidebarTreeSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, subscribe: settings.subscribe, version: settings.getVersion };
  const memory = new Map<string, unknown>(), listeners = new Set<() => void>();
  let version = 0;
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:320px;height:740px;display:flex;flex-direction:column";
  document.body.append(host);
  const root = createRoot(host), store = new RepoStore();
  const longLeaf = "search-with-a-long-unbroken-branch-name-".repeat(8);
  const branch = (name: string, isRemote = false): Branch => ({ name, target: name, upstream: null, ahead: name === "main" ? 2 : 0, behind: name === "main" ? 5 : 0, upstreamGone: name === "feature/search", isCurrent: name === "feature/checkout", isRemote });
  const worktree = (path: string, name: string): Worktree => ({ path, head: "0000000", branch: name, isMain: name === "feature/checkout", locked: false, prunable: false });
  const revealed: string[] = [];
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const group = (id: string) => host.querySelector<HTMLElement>(`[data-tree-id="${id}"]`);
  const toggle = (id: string) => group(id)?.querySelector<HTMLButtonElement>(":scope > .side-tree-toggle");
  const label = (container: HTMLElement | null | undefined, text: string) => [...(container?.querySelectorAll<HTMLElement>(".side-tree-label") ?? [])].find((element) => element.textContent === text)!;
  const row = (element: HTMLElement) => element.closest<HTMLElement>(".side-tree-row")!;
  const left = (element: HTMLElement, selector: string) => row(element).querySelector<HTMLElement>(selector)!.getBoundingClientRect().left;
  const near = (a: number, b: number) => Math.abs(a - b) <= 1;
  const sections = () => [...host.querySelectorAll<HTMLElement>(".side-section")].map((element) => element.dataset.section).join();
  const type = (input: HTMLInputElement, value: string) => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value); input.dispatchEvent(new Event("input", { bubbles: true })); };
  const widths: { width: number; rows: number; nestedOffset: number; longLabelWidth: number }[] = [];
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
    // a hosting remote, a second worktree and a pinned branch used to add sections; the board has none of them
    store.target = { provider: "github", host: "github.com", path: "fixture/shop-web", remote: "origin" };
    store.worktrees = [worktree("C:/fixture/shop-web", "feature/checkout"), worktree("C:/fixture/shop-web-search", "feature/search")];
    store.pinnedBranches = new Set(["main"]);
    store.tags = [{ name: "v1.10.0", target: "v1.10.0" }];
    store.stashes = [{ ref: "stash@{0}", hash: "stash-0", message: "WIP on main" }];
    store.reveal = (target) => { revealed.push(target); };
    root.render(createElement(Sidebar, { store }));
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
    // the board's sections in its order, then Stashes; no pull requests, issues, worktrees or pinned list
    ensure(sections() === "local,remote,tags,stashes", `The Branches tab must hold local branches, remotes and tags, then stashes: ${sections()}`);
    // heads: 26px, the count a neutral pill (none on Remotes, whose rows carry it), no buttons, Tags open from the start
    const head = (id: string) => host.querySelector<HTMLElement>(`[data-section="${id}"] > .side-head`)!;
    const count = (element: HTMLElement | null | undefined) => element?.querySelector<HTMLElement>(".side-count");
    for (const id of ["local", "remote", "tags", "stashes"]) ensure(near(head(id).getBoundingClientRect().height, 26) && !head(id).querySelector("button"), `The ${id} head is not a 26px row without buttons`);
    ensure(count(head("local"))?.textContent === "3" && count(head("tags"))?.textContent === "1" && count(head("stashes"))?.textContent === "1" && !count(head("remote")), "The heads must count local branches, tags and stashes, and leave the remotes to their rows");
    ensure(!!label(host.querySelector<HTMLElement>('[data-section="tags"]'), "v1.10.0"), "Tags must be open from the start");
    // the field: 28px with a 6px radius and a 13px magnifier, 10px under the switch and 10px over the first head
    const field = host.querySelector<HTMLElement>(".side-filter")!, input = field?.querySelector<HTMLInputElement>("input")!;
    ensure(field && input && input.getAttribute("aria-label") === t("Filter branches") && input.placeholder === t("Filter branches"), "The Filter branches field is missing");
    const fieldStyle = getComputedStyle(field), glass = field.querySelector("svg")!.getBoundingClientRect();
    ensure(near(field.getBoundingClientRect().height, 28) && fieldStyle.borderTopLeftRadius === "6px" && fieldStyle.borderTopWidth === "1px" && near(glass.width, 13), "The field is not 28px tall with a 6px radius, a 1px border and a 13px icon");
    ensure(near(field.getBoundingClientRect().top - host.querySelector<HTMLElement>(".side-modes")!.getBoundingClientRect().bottom, 10) && near(head("local").getBoundingClientRect().top - field.getBoundingClientRect().bottom, 10), "The field must stand 10px under the switch and 10px over the first head");
    // the current branch: the accent dot instead of an icon, its name semibold, its folder plain
    const current = row(label(group("l:feature")!, "checkout")), marker = current.querySelector<HTMLElement>(".lead > .side-current > span")!;
    ensure(marker && near(marker.getBoundingClientRect().width, 12) && !current.querySelector(".lead svg") && host.querySelectorAll(".side-branches .side-current").length === 1, "Only the current branch has the 12px current marker");
    ensure(Number(getComputedStyle(label(current, "checkout")).fontWeight) === 600 && Number(getComputedStyle(label(group("l:feature")!, "search")).fontWeight) === 400, "Only the current branch's name is semibold");
    ensure(getComputedStyle(toggle("l:feature")!.querySelector<HTMLElement>(".lead")!).color === getComputedStyle(row(label(group("l:feature")!, "search")).querySelector<HTMLElement>(".lead")!).color, "The folder of the current branch must stay neutral");
    // ahead and behind: plain monospaced text, no capsule
    const mainRow = row(label(host.querySelector<HTMLElement>('[data-section="local"]'), "main"));
    const counts = [...mainRow.querySelectorAll<HTMLElement>(".side-ab")];
    ensure(counts.map((element) => element.textContent).join(" ") === "↑2 ↓5" && counts.every((element) => { const style = getComputedStyle(element); return style.fontSize === "11px" && style.backgroundColor === "rgba(0, 0, 0, 0)" && Number(style.fontWeight) === 400; }), "Ahead and behind must be plain 11px text");
    // marks: only state that shows nowhere else (pinned, upstream gone); no hover eye, no worktree mark
    ensure(mainRow.querySelector(`[aria-label="${t("Pinned")}"]`) && row(label(group("l:feature")!, "search")).querySelector(`[data-tip="${t("The tracked remote branch was deleted")}"]`), "The pinned and upstream-gone marks are missing");
    ensure(!host.querySelector(".side-tree-row button.icon-btn") && ![...host.querySelectorAll<HTMLElement>(".side-tree-row [data-tip]")].some((element) => element.dataset.tip?.includes("shop-web-search")), "A row must not carry the hover eye or the worktree mark");
    for (const width of [240, 280, 320]) {
      host.style.width = `${width}px`;
      await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
      const localSection = host.querySelector<HTMLElement>('[data-section="local"]')!;
      const localMain = label(localSection, "main"), localFolder = label(toggle("l:feature")!, "feature");
      const remoteRoot = label(origin, "origin"), remoteMain = label(group("r:origin")!, "main");
      const remoteFolder = label(toggle("r:origin/feature")!, "feature"), nested = label(group("r:origin/feature")!, longLeaf);
      const tag = label(host.querySelector<HTMLElement>('[data-section="tags"]'), "v1.10.0");
      for (const selector of [".lead", ".side-tree-label"]) ensure(near(left(tag, selector), left(localMain, selector)), `Tag and branch columns differ at ${width}px`);
      // the field keeps the sidebar's 10px at each side
      const bounds = host.getBoundingClientRect(), fieldBox = field.getBoundingClientRect();
      ensure(near(fieldBox.left - bounds.left, 10) && near(bounds.right - fieldBox.right, 10), `The field left its 10px margins at ${width}px`);
      // the chevron of a head stands over the rows' disclosure column, and every count pill shares the right edge
      ensure(near(head("local").querySelector<SVGElement>(".chev")!.getBoundingClientRect().left, left(localMain, ".side-tree-disclosure")), `The head chevron left the disclosure column at ${width}px`);
      const pills = [count(head("local")), count(head("tags")), count(toggle("l:feature")), count(origin)].map((element) => element!.getBoundingClientRect());
      ensure(pills.every((rect) => near(rect.height, 18) && near(rect.right, pills[0].right)), `The count pills are not 18px tall at one right edge at ${width}px`);
      for (const selector of [".lead", ".side-tree-label"]) {
        ensure(near(left(localMain, selector), left(localFolder, selector)), `Local folder and branch columns differ at ${width}px`);
        ensure(near(left(remoteMain, selector), left(remoteFolder, selector)), `Remote folder and branch columns differ at ${width}px`);
        ensure(near(left(remoteMain, selector) - left(remoteRoot, selector), 18), `Remote children did not move one level at ${width}px`);
        ensure(near(left(nested, selector) - left(remoteFolder, selector), 18), `Folder leaves did not move one level at ${width}px`);
      }
      // stash rows keep their two lines; every other row is 26px
      const stashRows = [...host.querySelectorAll<HTMLElement>('[data-section="stashes"] .side-tree-row')];
      const rows = [...host.querySelectorAll<HTMLElement>(".side-tree-row")];
      ensure(stashRows.length === 1 && near(stashRows[0].querySelector<HTMLElement>(".lead")!.getBoundingClientRect().left, left(localMain, ".lead")), `Stash and branch icons differ at ${width}px`);
      ensure(rows.filter((element) => !stashRows.includes(element)).every((element) => near(element.getBoundingClientRect().height, 26)), `Tree row heights differ at ${width}px`);
      ensure(near(row(remoteFolder).getBoundingClientRect().top - row(remoteMain).getBoundingClientRect().top, 26), `Extra spacing separates sibling rows at ${width}px`);
      ensure(rows.every((element) => { const rect = element.getBoundingClientRect(); return rect.left >= bounds.left - 1 && rect.right <= bounds.right + 1; }), `A tree row overflowed the ${width}px sidebar`);
      ensure(nested.getBoundingClientRect().width > 0 && nested.scrollWidth > nested.clientWidth && getComputedStyle(nested).textOverflow === "ellipsis", `The long branch label did not truncate at ${width}px`);
      ensure(row(nested).dataset.tip?.includes(`origin/feature/${longLeaf}`), "The full long branch name is unavailable on hover");
      row(nested).click();
      ensure(revealed.at(-1) === `origin/feature/${longLeaf}`, "Clicking a nested branch did not reveal its commit");
      widths.push({ width, rows: rows.length, nestedOffset: left(nested, ".lead") - left(remoteFolder, ".lead"), longLabelWidth: nested.getBoundingClientRect().width });
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

    // the filter: names that contain the text, whatever its case; folders and sections with a match open, the others go
    host.style.width = "240px";
    toggle("r:origin")!.click();
    settings.set("collapsedSections", ["tags"]);
    ensure(await until(() => toggle("r:origin")?.getAttribute("aria-expanded") === "false" && !label(host.querySelector<HTMLElement>('[data-section="tags"]'), "v1.10.0")), "The remote and the Tags section did not fold before filtering");
    type(input, "  LONG-unbroken ");
    ensure(await until(() => sections() === "remote" && !!label(group("r:origin/feature")!, longLeaf)), `A match in a folded remote did not open it and hide the sections without one: ${sections()}`);
    ensure(store.branchFilter === "  LONG-unbroken " && toggle("r:origin")!.getAttribute("aria-expanded") === "true" && count(toggle("r:origin"))?.textContent === "1" && !group("r:upstream") && !label(group("r:origin")!, "main"), "The filter must leave only the matching branch, its folder and its remote");
    // a folder cannot be folded over its matches, and its remembered state is not touched
    toggle("r:origin")!.click(); await pause();
    ensure(!!label(group("r:origin/feature")!, longLeaf), "A click folded a folder that holds a match");
    type(input, "checkout");
    ensure(await until(() => sections() === "local,remote" && !label(group("l:feature")!, "search")), `"checkout" must leave the local and the remote branch: ${sections()}`);
    ensure(count(head("local"))?.textContent === "1" && count(toggle("l:feature"))?.textContent === "1" && group("l:feature")!.querySelector(".side-current") && Number(getComputedStyle(label(group("l:feature")!, "checkout")).fontWeight) === 600, "The current branch must stay, marked, when it matches, and the counts must be those of the rows shown");
    type(input, "V1.");
    ensure(await until(() => sections() === "tags" && !!label(host.querySelector<HTMLElement>('[data-section="tags"]'), "v1.10.0")), `A matching tag must open the folded Tags section alone: ${sections()}`);
    // nothing matches: the empty form of docs/design.md, inside the 240px sidebar, and its one plain action
    type(input, "zzz");
    ensure(await until(() => !!host.querySelector(".side-filter-empty .hosted-empty")), "No match did not show the empty form");
    const empty = host.querySelector<HTMLElement>(".side-filter-empty .hosted-empty")!, clear = empty.querySelector<HTMLButtonElement>("button")!;
    ensure(sections() === "" && empty.querySelector(".hosted-empty-title")?.textContent === t("No matching branches") && empty.querySelector(".hosted-empty-caption")?.textContent === t("No branch or tag name contains “{0}”.", "zzz") && empty.querySelectorAll("button").length === 1 && clear.textContent === t("Clear filter") && !clear.classList.contains("primary"), "The empty form needs its title, its caption and one plain Clear filter");
    const narrow = host.getBoundingClientRect();
    ensure([...empty.children].every((element) => { const rect = element.getBoundingClientRect(); return rect.width > 0 && rect.left >= narrow.left && rect.right <= narrow.right; }) && !!host.querySelector(".side-filter"), "The empty form leaves the 240px sidebar or took the field away");
    clear.click();
    ensure(await until(() => input.value === "" && sections() === "local,remote,tags,stashes"), `Clear filter did not bring every section back: ${sections()}`);
    ensure(store.branchFilter === "" && toggle("r:origin")!.getAttribute("aria-expanded") === "false" && toggle("l:feature")!.getAttribute("aria-expanded") === "true" && !label(host.querySelector<HTMLElement>('[data-section="tags"]'), "v1.10.0"), "Clearing the filter must restore the folders' and sections' remembered state");

    // "Pin to top": the loose main, feature/search from its folder and the current feature/checkout lead Local branches
    // in name order under their whole names; the folder keeps the rest, and the head still counts every branch
    const localRows = () => [...host.querySelectorAll<HTMLElement>('[data-section="local"] .side-tree-row')];
    const shown = () => localRows().map((element) => element.querySelector(".side-tree-label")?.textContent ?? "").join();
    const checkedOut: string[] = [];
    store.checkout = async (b) => { checkedOut.push(b.name); };
    const before = store.localBranches, reviews = branch("feature/reviews"), search = branch("feature/search");
    store.localBranches = [...before, reviews].sort((a, b) => a.name.localeCompare(b.name));
    store.setPinned(search, true);
    store.setPinned(branch("feature/checkout"), true);
    ensure(await until(() => shown() === "feature/checkout,feature/search,main,feature,reviews"), `Pinned branches must lead Local branches in name order, out of their folder: ${shown()}`);
    ensure(count(head("local"))?.textContent === "4" && count(toggle("l:feature"))?.textContent === "1", "The head must count every local branch and the folder only what it holds");
    const pinnedRows = localRows().slice(0, 3), folderLead = toggle("l:feature")!.querySelector<HTMLElement>(".lead")!.getBoundingClientRect().left;
    for (const element of pinnedRows) {
      const name = element.querySelector(".side-tree-label")!.textContent!;
      ensure(element.querySelector(`[aria-label="${t("Pinned")}"]`) && !element.closest(".side-tree-children") && element.draggable && element.dataset.tip?.startsWith(name + "|"), `The pinned row ${name} must carry the pin mark, stand outside its folder and drag and hover like any branch row`);
      ensure(near(element.querySelector<HTMLElement>(".lead")!.getBoundingClientRect().left, folderLead), `The pinned row ${name} must line up with the folders`);
    }
    ensure(!!pinnedRows[0].querySelector(".lead > .side-current") && Number(getComputedStyle(pinnedRows[0].querySelector<HTMLElement>(".side-tree-label")!).fontWeight) === 600 && host.querySelectorAll(".side-branches .side-current").length === 1, "The pinned current branch must keep its marker and its semibold name");
    for (const width of [240, 280]) {
      host.style.width = `${width}px`;
      await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
      const bounds = host.getBoundingClientRect();
      ensure(pinnedRows.every((element) => { const rect = element.getBoundingClientRect(), text = element.querySelector<HTMLElement>(".side-tree-label")!; return near(rect.height, 26) && rect.left >= bounds.left - 1 && rect.right <= bounds.right + 1 && text.scrollWidth <= text.clientWidth; }), `A pinned row was cut or left the ${width}px sidebar`);
    }
    // a pinned row is an ordinary branch row: click reveals, double-click checks out, dragging carries the branch
    pinnedRows[1].click();
    pinnedRows[1].dispatchEvent(new MouseEvent("dblclick", { bubbles: true }));
    const carried = new DataTransfer();
    pinnedRows[1].dispatchEvent(new DragEvent("dragstart", { bubbles: true, dataTransfer: carried }));
    const dragged = drag.payload === branchPayload + "feature/search" && carried.getData("text/plain") === branchPayload + "feature/search";
    pinnedRows[1].dispatchEvent(new DragEvent("dragend", { bubbles: true }));
    ensure(revealed.at(-1) === "feature/search" && checkedOut.at(-1) === "feature/search" && dragged && drag.payload === null, "A pinned row must reveal, check out and drag like any branch row");
    // the field narrows pinned rows by name, and a pinned match keeps its place at the top
    type(input, "search");
    ensure(await until(() => shown() === "feature/search" && count(head("local"))?.textContent === "1"), `A pinned match must stay at the top on its own: ${shown()}`);
    type(input, "e");
    ensure(await until(() => shown() === "feature/checkout,feature/search,feature,reviews"), `Pinned matches must stay ahead of the folders: ${shown()}`);
    type(input, "");
    // a folder left empty goes; unpinning puts the branches back in their folder at once, its fold remembered
    store.setPinned(reviews, true);
    ensure(await until(() => shown() === "feature/checkout,feature/reviews,feature/search,main" && !group("l:feature")), `A folder left empty must go: ${shown()}`);
    store.setPinned(reviews, false);
    store.setPinned(search, false);
    ensure(await until(() => shown() === "feature/checkout,main,feature,reviews,search" && count(toggle("l:feature"))?.textContent === "2"), `Unpinning must put the branches back in their folder: ${shown()}`);
    ensure(!localRows().slice(2).some((element) => element.querySelector(`[aria-label="${t("Pinned")}"]`)), "Unpinned rows must lose the pin mark");
    store.setPinned(branch("feature/checkout"), false);
    ensure(await until(() => shown() === "main,feature,checkout,reviews,search"), `Unpinning the current branch must put it back in its folder: ${shown()}`);
    store.localBranches = before;

    // the rail's flyout has no field and is not filtered
    store.setBranchFilter("zzz");
    root.render(createElement(Sidebar, { store, flyout: "remote" }));
    ensure(await until(() => sections() === "remote" && !!toggle("r:origin") && !!toggle("r:upstream")), `The rail's flyout must list its section whatever the filter says: ${sections()}`);
    ensure(!host.querySelector(".side-filter") && !host.querySelector(".hosted-empty"), "The rail's flyout must not show the field or the empty form");
    return [true, JSON.stringify({ widths, sections: "local,remote,tags,stashes", field: "28px, 10px above and below", disclosureFocus: true, collapseAndReopen: true, retainedNestedExpansion: true, filter: "matches open folded folders and sections, no match shows the empty form, clearing restores the remembered state", pinned: "first in name order under whole names, out of their folders, filtered in place, back in the folder when unpinned", revealed: revealed.length })];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally {
    root.unmount(); host.remove();
    settings.get = original.get; settings.set = original.set; settings.subscribe = original.subscribe; settings.getVersion = original.version;
  }
}
