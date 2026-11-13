import { createRoot } from "react-dom/client";
import { RepoStore } from "@/entities/repo";
import { repositoryDestinations, workspaceDestinations } from "@/entities/git";
import { NavigationSidebar } from "@/widgets/sidebar";
import { t } from "@/shared/i18n";
import { settings } from "@/shared/config";
import { useObserve } from "@/shared/lib";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 35));
/** The page list and its icon rail, without a repository and with one, without external calls. */
export async function navigationSelfTest(): Promise<[boolean, string]> {
  const original = { get: settings.get, set: settings.set, subscribe: settings.subscribe, version: settings.getVersion };
  const memory = new Map<string, unknown>(), listeners = new Set<() => void>();
  let version = 0;
  const host = document.createElement("div"); host.style.cssText = "position:fixed;left:-10000px;top:0;width:850px;height:900px"; document.body.append(host);
  const root = createRoot(host), store = new RepoStore();
  let opened = 0;
  const ensure = (condition: unknown, message: string) => { if (!condition) throw new Error(message); };
  // each page's data loading is checked by its own self-test
  const navigate = store.navigate.bind(store); store.navigate = (page) => navigate(page, false);
  const row = (page: string) => host.querySelector<HTMLButtonElement>(`.workspace-nav-item[data-page="${page}"]`);
  const rows = () => [...host.querySelectorAll<HTMLButtonElement>(".workspace-nav-scroll .workspace-nav-item")];
  function Fixture({ compact }: { compact: boolean }) { useObserve(store); return <div style={{ width: compact ? 52 : 250, height: 780 }}><NavigationSidebar store={store} openSettings={() => { opened++; }} compact={compact} /></div>; }
  try {
    // Navigation remembers pages even with data loading disabled; keep those writes out of the real settings timer.
    settings.get = <T,>(key: string, fallback: T): T => (memory.has(key) ? memory.get(key) : fallback) as T;
    settings.set = (key, value) => { memory.set(key, value); version++; listeners.forEach((listener) => listener()); };
    settings.subscribe = (listener) => { listeners.add(listener); return () => { listeners.delete(listener); }; };
    settings.getVersion = () => version;
    root.render(<Fixture compact={false} />); await pause();
    ensure(rows().map((button) => button.dataset.page).join(",") === "home,repository,compare,rebase,code,pullRequests,issues,actions,releases,projects,account,flows", `The sidebar must list every page: ${rows().map((button) => button.dataset.page).join(",")}`);
    ensure(!host.querySelector("input"), "The sidebar must not have a search box");
    // without a repository the page list disables the pages that need one and says why under their section
    for (const page of workspaceDestinations) {
      ensure(row(page)?.disabled === repositoryDestinations.has(page), `Only pages that need a repository may be disabled before opening one: ${page}`);
      if (!repositoryDestinations.has(page)) { row(page)!.click(); await pause(); ensure(store.destination === page, `The initial menu did not select ${page}`); }
    }
    ensure(host.querySelectorAll(".workspace-nav-why").length === 3, "Each section with a blocked page must say why");
    row("issues")!.click(); await pause(); ensure(store.destination === "issues" && row("issues")?.getAttribute("aria-current") === "page", "Issues must open without a repository");
    row("releases")!.click(); await pause(); ensure(store.destination === "releases", "Releases must open without a repository");
    row("projects")!.click(); await pause(); ensure(store.destination === "projects", "Projects must open without a repository");
    row("account")!.click(); await pause(); ensure(store.destination === "account", "Account must open without a repository");
    store.path = "C:/fixture/navigation"; store.changed(); await pause();
    for (const page of workspaceDestinations) { row(page)!.click(); await pause(); ensure(store.destination === page && row(page)?.getAttribute("aria-current") === "page", `Navigation did not select ${page}`); }
    const groups = [...host.querySelectorAll(".workspace-nav-group")].map((group) => group.textContent?.trim());
    ensure(groups.join("|") === [t("Repository"), "GitHub", t("Tools")].join("|"), `Unexpected group titles: ${groups.join("|")}`);
    host.querySelector<HTMLButtonElement>(".workspace-nav-footer button")!.click(); ensure(opened === 1, "Settings footer did not open preferences");
    // the toolbar's sidebar toggle folds the list (docs/design.md › App shell)
    ensure(!host.querySelector(".workspace-nav-toggle"), "The page list must not carry a toggle of its own");
    store.target = { provider: "gitlab", host: "gitlab.example.com", path: "demo/repo", remote: "origin" }; store.changed(); await pause();
    const navText = host.querySelector("nav")?.textContent ?? "";
    ensure(["Merge requests", "Pipelines"].every((value) => navText.includes(t(value))) && navText.includes("GitLab"), "Provider-specific menu names were not applied");
    root.render(<Fixture compact />); await pause();
    ensure(host.querySelector("nav")?.getBoundingClientRect().width === 52, "The rail must be 52px wide");
    // the toolbar's sidebar toggle expands the rail (docs/design.md › App shell)
    ensure(!host.querySelector(".workspace-nav-toggle"), "The rail must not carry a toggle of its own");
    ensure(rows().every((button) => !!button.getAttribute("aria-label") && !!button.dataset.tip && button.querySelector("svg")!.getBoundingClientRect().width > 0), "Rail icons lost their labels, tooltips or visible symbols");
    ensure(row("flows")?.getAttribute("aria-current") === "page", "The rail lost the current page");
    row("home")!.click(); await pause(); ensure(store.destination === "home", "Rail icons did not route to their pages");
    return [true, "All twelve pages, blocked pages disabled with a reason before a repository opens, group titles, settings without a toggle of its own, GitLab names, 52px rail with labels, tooltips, current page and routing"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally {
    root.unmount(); host.remove();
    settings.get = original.get; settings.set = original.set; settings.subscribe = original.subscribe; settings.getVersion = original.version;
  }
}
