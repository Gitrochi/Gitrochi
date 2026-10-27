import { createRoot } from "react-dom/client";
import { RepoPage } from "@/pages/repo";
import { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 60));

/** The real window shell: the page list folds into a rail on the repository screen, expands again, and the other pages are full-width. */
export async function compactNavigationSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, subscribe: settings.subscribe, version: settings.getVersion, run: ipc.run, http: ipc.http, write: ipc.writeText };
  const memory = new Map<string, unknown>([["avatarFetch", false], ["recentRepositories", []]]);
  const listeners = new Set<() => void>(), unexpected: string[] = [];
  let version = 0, opened = 0;
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:1440px;height:720px";
  document.body.append(host);
  const root = createRoot(host), store = new RepoStore();
  // the Home toolbar's account control reads the global Git author; this fixture runs no processes
  store.loadGlobalIdentity = async () => {};
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const nav = () => host.querySelector<HTMLElement>(".workspace-navigation")!;
  const row = (page: string) => host.querySelector<HTMLButtonElement>(`.workspace-nav-item[data-page="${page}"]`);
  const toggle = () => host.querySelector<HTMLButtonElement>(".workspace-nav-toggle")!;
  const isCompact = () => host.querySelector(".main")?.getAttribute("data-navigation-mode") === "compact";
  const settle = async () => { await pause(); await pause(); };
  try {
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    settings.set = (key, value) => { memory.set(key, value); version++; listeners.forEach((listener) => listener()); };
    settings.subscribe = (listener) => { listeners.add(listener); return () => { listeners.delete(listener); }; };
    settings.getVersion = () => version;
    ipc.run = async () => { unexpected.push("process"); throw new Error("Navigation fixture blocked process"); };
    ipc.http = async () => { unexpected.push("network"); throw new Error("Navigation fixture blocked network"); };
    ipc.writeText = async () => { unexpected.push("write"); throw new Error("Navigation fixture blocked write"); };
    root.render(<RepoPage store={store} openSettings={() => { opened++; }} />);
    await settle();
    ensure(!isCompact() && toggle().getAttribute("aria-expanded") === "true", "Home must show the full page list");
    ensure(!!host.querySelector(".welcome") && host.querySelector(".toolbar.no-repository .account-quick-trigger") && !host.querySelector(".toolbar .tool"), "Home without a repository must show the welcome screen and only the account control in the toolbar");
    ensure(row("repository")?.disabled && !row("issues")?.disabled, "The page list must keep the empty-repository access rules");
    store.path = "C:/fixture/compact-navigation"; store.headBranch = "main"; store.navigate("repository"); await settle();
    ensure(isCompact() && nav().getBoundingClientRect().width === 56, "Opening the repository screen must fold the page list into a 56px rail");
    ensure(host.querySelector(".repository-screen > .sidebar") && host.querySelector(".repository-screen > .center") && host.querySelector(".repository-screen > .inspector"), "The repository screen must show its three columns");
    ensure(!!host.querySelector(".toolbar") && !host.querySelector(".workspace-location") && !host.querySelector('[role="tab"]'), "The icon toolbar must be back, without a page header or tab strip");
    ensure(toggle().getAttribute("aria-label") === t("Expand sidebar") && row("repository")?.getAttribute("aria-current") === "page", "The rail has no expand control or lost the current page");
    toggle().click(); await settle();
    ensure(!isCompact() && host.querySelector(".navigation-splitter") && host.querySelector(".repository-screen"), "Expanding from the rail must show the page list beside the repository screen");
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "b", ctrlKey: true, bubbles: true })); await settle();
    ensure(isCompact(), "Ctrl+B must fold the page list");
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "b", ctrlKey: true, bubbles: true })); await settle();
    ensure(!isCompact(), "Ctrl+B must expand the page list again");
    host.querySelector<HTMLButtonElement>(".repository-screen > .sidebar .icon-btn")!.click(); await settle();
    ensure(host.querySelector(".repository-screen > .sidebar-rail") && !host.querySelector(".repository-screen > .sidebar"), "The branch list must fold into its own rail");
    host.querySelector<HTMLButtonElement>(".repository-screen > .sidebar-rail .icon-btn")!.click(); await settle();
    ensure(host.querySelector(".repository-screen > .sidebar"), "The branch rail must expand the branch list again");
    // Issues needs no repository process; the Code page would read the tree
    row("issues")!.click(); await settle();
    ensure(store.destination === "issues" && !host.querySelector(".repository-screen") && host.querySelector(".workspace-pane > .workspace-page"), "Other pages must be full-width");
    store.showTerminal = true; store.changed(); await settle();
    ensure(host.querySelector(".workspace-pane > .term-panel"), "The terminal must sit below a full-width page");
    row("repository")!.click(); await settle();
    ensure(isCompact() && host.querySelector(".repository-screen > .center > .term-panel"), "Returning to the repository screen must fold the rail and put the terminal under the graph");
    nav().querySelector<HTMLButtonElement>(".workspace-nav-footer button")!.click();
    ensure(opened === 1, "The rail's Settings button did not open preferences");
    ensure(unexpected.length === 0, `Navigation triggered external work: ${unexpected.join(", ")}`);
    return [true, "Welcome without a toolbar; the repository screen folds the page list into a 56px rail with three columns, an icon toolbar and no tab strip; rail and Ctrl+B expand and fold; branch list folds into its rail; full-width pages with the terminal below, the repository screen with it under the graph; no network, processes or writes"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally {
    root.unmount(); host.remove();
    settings.get = original.get; settings.set = original.set; settings.subscribe = original.subscribe; settings.getVersion = original.version;
    ipc.run = original.run; ipc.http = original.http; ipc.writeText = original.write;
  }
}
