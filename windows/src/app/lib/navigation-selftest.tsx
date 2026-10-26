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
  const host = document.createElement("div"); host.style.cssText = "position:fixed;left:-10000px;top:0;width:850px;height:900px"; document.body.append(host);
  const root = createRoot(host), store = new RepoStore();
  const savedDestinations = settings.get("workspaceDestinations", {});
  let opened = 0, toggles = 0;
  const ensure = (condition: unknown, message: string) => { if (!condition) throw new Error(message); };
  // each page's data loading is checked by its own self-test
  const navigate = store.navigate.bind(store); store.navigate = (page) => navigate(page, false);
  const row = (page: string) => host.querySelector<HTMLButtonElement>(`.workspace-nav-item[data-page="${page}"]`);
  const rows = () => [...host.querySelectorAll<HTMLButtonElement>(".workspace-nav-scroll .workspace-nav-item")];
  function Fixture({ compact }: { compact: boolean }) { useObserve(store); return <div style={{ width: compact ? 56 : 250, height: 780 }}><NavigationSidebar store={store} openSettings={() => { opened++; }} compact={compact} onToggle={() => { toggles++; }} /></div>; }
  try {
    root.render(<Fixture compact={false} />); await pause();
    ensure(rows().map((button) => button.dataset.page).join(",") === "home,repository,compare,rebase,code,pullRequests,issues,actions,account,flows", `The sidebar must list the ten pages in order: ${rows().map((button) => button.dataset.page).join(",")}`);
    ensure(!host.querySelector("input"), "The sidebar must not have a search box");
    for (const page of workspaceDestinations) ensure(row(page)?.disabled === repositoryDestinations.has(page), `Incorrect empty-repository access: ${page}`);
    row("issues")!.click(); await pause(); ensure(store.destination === "issues" && row("issues")?.getAttribute("aria-current") === "page", "Issues must open without a repository");
    row("account")!.click(); await pause(); ensure(store.destination === "account", "Account must open without a repository");
    store.path = "C:/fixture/navigation"; store.changed(); await pause();
    for (const page of workspaceDestinations) { row(page)!.click(); await pause(); ensure(store.destination === page && row(page)?.getAttribute("aria-current") === "page", `Navigation did not select ${page}`); }
    const groups = [...host.querySelectorAll(".workspace-nav-group")].map((group) => group.textContent?.trim());
    ensure(groups.join("|") === [t("Workspace"), "GitHub", t("Tools")].join("|"), `Unexpected group titles: ${groups.join("|")}`);
    host.querySelector<HTMLButtonElement>(".workspace-nav-footer button")!.click(); ensure(opened === 1, "Settings footer did not open preferences");
    host.querySelector<HTMLButtonElement>(".workspace-nav-toggle")!.click(); ensure(toggles === 1, "The collapse control did not ask to fold the page list");
    store.target = { provider: "gitlab", host: "gitlab.example.com", path: "demo/repo", remote: "origin" }; store.changed(); await pause();
    const navText = host.querySelector("nav")?.textContent ?? "";
    ensure(["Merge requests", "Pipelines"].every((value) => navText.includes(t(value))) && navText.includes("GitLab"), "Provider-specific menu names were not applied");
    root.render(<Fixture compact />); await pause();
    ensure(host.querySelector("nav")?.getBoundingClientRect().width === 56, "The rail must be 56px wide");
    ensure(host.querySelector(".workspace-nav-toggle")?.getAttribute("aria-label") === t("Expand sidebar"), "The rail has no accessible expand control");
    ensure(rows().every((button) => !!button.getAttribute("aria-label") && !!button.dataset.tip && button.querySelector("svg")!.getBoundingClientRect().width > 0), "Rail icons lost their labels, tooltips or visible symbols");
    ensure(row("flows")?.getAttribute("aria-current") === "page", "The rail lost the current page");
    row("home")!.click(); await pause(); ensure(store.destination === "home", "Rail icons did not route to their pages");
    return [true, "Ten pages in order, no search box, Issues and Account without a repository, every page with one, group titles, settings and collapse controls, GitLab names, 56px rail with labels, tooltips, current page and routing"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); settings.set("workspaceDestinations", savedDestinations); }
}
