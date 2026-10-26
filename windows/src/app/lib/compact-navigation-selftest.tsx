import { createRoot } from "react-dom/client";
import { RepoPage } from "@/pages/repo";
import { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 60));

/** 실제 저장소 화면을 접고 넓혀도 아이콘·선택·설정·검색을 계속 사용할 수 있는지 확인한다. */
export async function compactNavigationSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, subscribe: settings.subscribe, version: settings.getVersion, run: ipc.run, http: ipc.http, write: ipc.writeText };
  const memory = new Map<string, unknown>([["navigationToolsExpanded", false], ["pinnedRepositoryPages", ["changes", "branches"]], ["avatarFetch", false], ["recentRepositories", []]]);
  const listeners = new Set<() => void>(), unexpected: string[] = [], navigated: string[] = [];
  let version = 0, opened = 0;
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:1440px;height:720px";
  document.body.append(host);
  const root = createRoot(host), store = new RepoStore();
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const nav = () => host.querySelector<HTMLElement>(".workspace-navigation")!;
  const row = (page: string) => host.querySelector<HTMLButtonElement>(`.workspace-nav-item[data-page="${page}"]`);
  const toggle = () => host.querySelector<HTMLButtonElement>(".workspace-nav-toggle")!;
  const resize = async (width: number) => { host.style.width = `${width}px`; await pause(); await pause(); };
  const isCompact = () => host.querySelector(".main")?.getAttribute("data-navigation-mode") === "compact";
  try {
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    settings.set = (key, value) => { memory.set(key, value); version++; listeners.forEach((listener) => listener()); };
    settings.subscribe = (listener) => { listeners.add(listener); return () => { listeners.delete(listener); }; };
    settings.getVersion = () => version;
    ipc.run = async () => { unexpected.push("process"); throw new Error("Navigation fixture blocked process"); };
    ipc.http = async () => { unexpected.push("network"); throw new Error("Navigation fixture blocked network"); };
    ipc.writeText = async () => { unexpected.push("write"); throw new Error("Navigation fixture blocked write"); };
    store.navigate = (page) => { navigated.push(page); return true; };
    root.render(<RepoPage store={store} openSettings={() => { opened++; }} />);
    await pause(); await pause();
    ensure(!isCompact() && toggle().getAttribute("aria-expanded") === "true", "Wide window must initially show the full menu");
    ensure(row("repository")?.disabled && !row("repositories")?.disabled, "Compact mode must preserve empty-repository access rules");
    toggle().click(); await pause();
    ensure(isCompact() && nav().getBoundingClientRect().width === 56, "Collapsing must leave a 56px icon rail");
    ensure(toggle().getAttribute("aria-label") === t("Expand sidebar"), "Compact rail has no accessible restore control");
    const compactRows = [...nav().querySelectorAll<HTMLButtonElement>(".workspace-nav-item")];
    ensure(compactRows.every((button) => !!button.getAttribute("aria-label") && !!button.dataset.tip && button.querySelector("svg")!.getBoundingClientRect().width > 0), "Compact icons lost their labels, tooltips or visible symbols");
    ensure(row("assistant") && row("agents") && row("worktrees") && row("operations"), "Collapsed tools must remain accessible as icons");
    ensure(row("changes") && row("branches"), "Pinned tools disappeared from the icon rail");
    await resize(900); await resize(1200);
    ensure(isCompact(), "Window resizing must preserve an explicitly collapsed menu");
    toggle().click(); await pause();
    ensure(!isCompact() && host.querySelector(".sidebar-splitter"), "Expanding must restore the menu and resize handle");
    await resize(900);
    ensure(isCompact() && !host.querySelector(".sidebar-splitter"), "Narrow windows must keep icons visible without an empty divider");
    nav().querySelector<HTMLButtonElement>(".workspace-nav-footer button")!.click();
    row("repositories")!.click();
    ensure(opened === 1 && navigated.includes("repositories"), "Compact Settings and library actions did not work");
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "k", ctrlKey: true, bubbles: true }));
    await pause();
    const search = host.querySelector<HTMLInputElement>(".workspace-nav-search input");
    ensure(!isCompact() && search === document.activeElement, "Ctrl+K must expand the rail and focus page search");
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(search, t("Rebase"));
    search!.dispatchEvent(new Event("input", { bubbles: true })); await pause();
    ensure(row("rebase"), "Expanded search must still find an unpinned repository tool");
    toggle().click(); await pause();
    ensure(isCompact() && row("projects") && !row("rebase"), "Collapsing search must restore the full rail instead of leaving filtered icons");
    store.path = "C:/fixture/compact-navigation"; store.destination = "repository"; store.repositorySection = "branches"; store.changed(); await pause();
    ensure(row("branches")?.getAttribute("aria-current") === "page", "Selected pinned tool lost its active icon state");
    row("changes")!.click(); row("projects")!.click();
    ensure(navigated.includes("changes") && navigated.includes("projects"), "Pinned and hosting icons did not route to their pages");
    const previewNavigation = navigated.length;
    row("repository")!.dispatchEvent(new MouseEvent("mouseover", { bubbles: true })); await pause();
    ensure(document.querySelector(".workspace-nav-preview .side-head"), "Hovering the repository icon must expose its lists");
    const branches = row("branches")!;
    branches.focus(); branches.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })); await pause();
    const preview = document.querySelector<HTMLElement>(".workspace-nav-preview")!;
    ensure(preview?.getAttribute("aria-label") === t("Branches") && preview.contains(document.activeElement), "ArrowRight must focus the branch flyout without navigating");
    ensure(navigated.length === previewNavigation, "Opening a flyout must preserve the active workspace");
    preview.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })); await pause();
    ensure(!document.querySelector(".workspace-nav-preview") && document.activeElement === branches, "Escape must dismiss the flyout and restore its icon focus");
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "b", ctrlKey: true, bubbles: true })); await pause();
    ensure(!isCompact(), "Ctrl+B must expand the narrow icon rail");
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "b", metaKey: true, bubbles: true })); await pause();
    ensure(isCompact(), "Command+B must collapse the navigation too");
    await resize(1200);
    ensure(!isCompact(), "Automatically compacted menu must expand when space returns");
    ensure(unexpected.length === 0, `Navigation triggered external work: ${unexpected.join(", ")}`);
    return [true, "56px persistent icons; manual and automatic collapse; wide restoration; pinned routes and selected state; Settings; accessible labels and tooltips; Ctrl+K search; Ctrl/Command+B; hover and keyboard flyouts; no network, processes or writes"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally {
    root.unmount(); host.remove();
    settings.get = original.get; settings.set = original.set; settings.subscribe = original.subscribe; settings.getVersion = original.version;
    ipc.run = original.run; ipc.http = original.http; ipc.writeText = original.write;
  }
}
