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
  const frame = () => host.querySelector<HTMLElement>(".navigation")!;
  const row = (page: string) => host.querySelector<HTMLButtonElement>(`.workspace-nav-item[data-page="${page}"]`);
  // the toolbar's sidebar toggle folds and expands the page list; the rail has no toggle of its own
  const toggle = () => host.querySelector<HTMLButtonElement>(".toolbar .sidebar-toggle")!;
  const isCompact = () => host.querySelector(".main")?.getAttribute("data-navigation-mode") === "compact";
  const settle = async () => {
    await pause(); await pause();
    await Promise.all(frame().getAnimations().map((animation) => animation.finished.catch(() => {})));
    await pause();
  };
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
    ensure(!!host.querySelector(".home-page") && host.querySelector(".toolbar.no-repository .account-quick-trigger") && !host.querySelector(".toolbar .tool:not(.sidebar-toggle)"), "Home without a repository must show the Home page and, beside the sidebar toggle and the repository button, only the account control in the toolbar");
    // the page list disables pages that need a repository and says why; Issues works without one
    ensure(row("repository")?.disabled && !row("issues")?.disabled && !!host.querySelector(".workspace-nav-why"), "Without a repository the page list must disable Repository with its reason and keep Issues");
    for (const destination of ["repository", "code", "pullRequests", "actions", "flows"] as const) {
      store.navigate(destination); await settle();
      ensure(store.destination === destination && !!host.querySelector(".workspace-repository-required") && !host.querySelector(".repository-screen"), `The ${destination} page must offer a repository chooser without starting local tools`);
    }
    store.path = "C:/fixture/compact-navigation"; store.headBranch = "main"; store.navigate("repository"); await settle();
    ensure(isCompact() && frame().getBoundingClientRect().width === 52, "Opening the repository screen must fold the page list into a 52px rail");
    ensure(host.querySelector(".repository-screen > .sidebar") && host.querySelector(".repository-screen > .center") && host.querySelector(".repository-screen > .inspector"), "The repository screen must show its three columns");
    ensure(!!host.querySelector(".toolbar") && !host.querySelector(".workspace-location") && !host.querySelector('[role="tab"]'), "The icon toolbar must be back, without a page header or tab strip");
    ensure(toggle().getAttribute("aria-label") === t("Expand sidebar") && row("repository")?.getAttribute("aria-current") === "page", "The rail has no expand control or lost the current page");
    const repositoryButton = row("repository"), toggleButton = toggle();
    const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
    const transitionDuration = getComputedStyle(frame()).transitionDuration.split(",").map(parseFloat);
    ensure(reducedMotion ? transitionDuration.every((duration) => duration === 0) : transitionDuration.some((duration) => duration > 0), "Navigation motion must follow the reduced-motion preference");
    toggleButton.focus(); toggleButton.click(); await pause();
    const openingWidth = frame().getBoundingClientRect().width;
    ensure(reducedMotion ? openingWidth === 240 : openingWidth > 52 && openingWidth < 240, `The page list must ${reducedMotion ? "open immediately with reduced motion" : "animate between its rail and saved widths"}: ${openingWidth}`);
    ensure(row("repository") === repositoryButton && toggle() === toggleButton && document.activeElement === toggleButton, "Sidebar motion must preserve mounted controls and keyboard focus");
    await settle();
    ensure(!isCompact() && host.querySelector(".navigation-splitter") && host.querySelector(".repository-screen"), "Expanding from the rail must show the page list beside the repository screen");
    host.querySelector<HTMLElement>(".navigation-splitter")!.dispatchEvent(new MouseEvent("mousedown", { clientX: 240, bubbles: true })); await pause();
    window.dispatchEvent(new MouseEvent("mousemove", { clientX: 280 })); await pause();
    ensure(frame().getBoundingClientRect().width === 280 && getComputedStyle(frame()).transitionDuration === "0s", "Dragging the navigation edge must resize immediately without animation lag");
    window.dispatchEvent(new MouseEvent("mouseup")); await settle();
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "b", ctrlKey: true, bubbles: true })); await settle();
    ensure(isCompact(), "Ctrl+B must fold the page list");
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "b", ctrlKey: true, bubbles: true })); await settle();
    ensure(!isCompact() && frame().getBoundingClientRect().width === 280, "Ctrl+B must expand the page list to its resized width again");
    host.querySelector<HTMLButtonElement>(".repository-screen > .sidebar .icon-btn")!.click(); await settle();
    ensure(host.querySelector(".repository-screen > .sidebar-rail") && !host.querySelector(".repository-screen > .sidebar"), "The branch list must fold into its own rail");
    host.querySelector<HTMLButtonElement>(".repository-screen > .sidebar-rail .icon-btn")!.click(); await settle();
    ensure(host.querySelector(".repository-screen > .sidebar"), "The branch rail must expand the branch list again");
    // Issues needs no repository process; the Code page would read the tree
    row("issues")!.click(); await settle();
    const pane = host.querySelector<HTMLElement>(".workspace-pane"), page = host.querySelector<HTMLElement>(".workspace-pane > .workspace-page");
    const paneWidth = pane?.getBoundingClientRect().width ?? 0, pageWidth = page?.getBoundingClientRect().width ?? 0;
    ensure(store.destination === "issues" && !host.querySelector(".repository-screen") && !page?.querySelector(".page-header") && page?.getAttribute("aria-label") === t("Issues") && paneWidth > 0 && pageWidth > 0 && Math.abs(pageWidth - paneWidth) <= 1, `Other pages must be full-width: destination=${store.destination}; pane=${paneWidth}; page=${pageWidth}`);
    store.showTerminal = true; store.changed(); await settle();
    ensure(host.querySelector(".workspace-pane > .term-panel"), "The terminal must sit below a full-width page");
    row("repository")!.click(); await settle();
    ensure(isCompact() && host.querySelector(".repository-screen > .center > .term-panel"), "Returning to the repository screen must fold the rail and put the terminal under the graph");
    nav().querySelector<HTMLButtonElement>(".workspace-nav-footer button")!.click();
    ensure(opened === 1, "The rail's Settings button did not open preferences");
    ensure(unexpected.length === 0, `Navigation triggered external work: ${unexpected.join(", ")}`);
    return [true, "Welcome without a toolbar; the repository screen folds the page list into a 52px rail with three columns, an icon toolbar and no tab strip; rail and Ctrl+B animate without replacing controls or losing focus, respect reduced motion, and restore a dragged width without resize lag; branch list folds into its rail; full-width pages with the terminal below, the repository screen with it under the graph; no network, processes or writes"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally {
    root.unmount(); host.remove();
    settings.get = original.get; settings.set = original.set; settings.subscribe = original.subscribe; settings.getVersion = original.version;
    ipc.run = original.run; ipc.http = original.http; ipc.writeText = original.write;
  }
}
