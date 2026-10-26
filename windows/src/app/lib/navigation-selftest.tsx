import { createRoot } from "react-dom/client";
import { RepoStore } from "@/entities/repo";
import { isRepositorySection, repositoryDestinations, repositorySections, workspaceDestinations, type WorkspaceDestination } from "@/entities/git";
import { RepositoryTabs } from "@/pages/repo";
import { NavigationSidebar } from "@/widgets/sidebar";
import { t } from "@/shared/i18n";
import { settings } from "@/shared/config";
import { useObserve } from "@/shared/lib";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 35));
/** 실제 메뉴·통합 작업 탭·고정·키보드를 외부 호출 없이 확인한다. */
export async function navigationSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div"); host.style.cssText = "position:fixed;left:-10000px;top:0;width:850px;height:900px"; document.body.append(host);
  const root = createRoot(host), store = new RepoStore();
  const expanded = settings.get("navigationToolsExpanded", true), pinned = settings.get<unknown>("pinnedRepositoryPages", []);
  const savedDestinations = settings.get("workspaceDestinations", {}), savedSections = settings.get("workspaceRepositorySections", {});
  let opened = 0;
  const ensure = (condition: unknown, message: string) => { if (!condition) throw new Error(message); };
  // 각 작업 화면의 데이터 로드는 별도 selftest에서 확인한다.
  const navigate = store.navigate.bind(store); store.navigate = (page) => navigate(page, false);
  const row = (page: WorkspaceDestination) => host.querySelector<HTMLButtonElement>(`.workspace-nav-item[data-page="${page}"]`);
  const matches = (page: WorkspaceDestination) => store.destination === (isRepositorySection(page) ? "repository" : page) && (!isRepositorySection(page) || store.repositorySection === page);
  const tab = (section: string) => host.querySelector<HTMLButtonElement>(`[role="tab"][data-section="${section}"]`)!;
  function Fixture() { useObserve(store); return <><div style={{ width: 250, height: 780 }}><NavigationSidebar store={store} openSettings={() => { opened++; }} /></div><RepositoryTabs store={store} /></>; }
  try {
    settings.set("navigationToolsExpanded", true); settings.set("pinnedRepositoryPages", []);
    root.render(<Fixture />); await pause();
    const defaultPages = workspaceDestinations.filter((page) => !isRepositorySection(page));
    ensure(host.querySelectorAll(".workspace-nav-item").length === defaultPages.length + 1, "Default sidebar must consolidate six tools into Repository");
    for (const page of defaultPages) ensure(row(page)?.disabled === repositoryDestinations.has(page), `Incorrect empty-repository access: ${page}`);
    for (const section of repositorySections) ensure(!row(section), `Unpinned tool is duplicated in the sidebar: ${section}`);
    row("repositories")!.click(); await pause(); ensure(matches("repositories"), "Repository library is unavailable without a repository");
    store.path = "C:/fixture/navigation"; store.changed(); await pause();
    for (const page of defaultPages) {
      row(page)!.click(); await pause(); ensure(matches(page) && row(page)?.getAttribute("aria-current") === "page", `Navigation did not select ${page}`);
    }
    row("repository")!.click(); await pause(); ensure(host.querySelectorAll('[role="tab"]').length === 6, "Repository must expose all six work tabs");
    for (const section of repositorySections) {
      tab(section).click(); await pause(); ensure(matches(section) && tab(section).getAttribute("aria-selected") === "true", `Repository tab did not select ${section}`);
    }
    tab("code").dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })); await pause(); ensure(matches("changes") && document.activeElement === tab("changes"), "Arrow keys must wrap between repository tabs");
    tab("changes").dispatchEvent(new KeyboardEvent("keydown", { key: "End", bubbles: true })); await pause(); ensure(matches("code"), "End must select the last repository tab");
    tab("code").dispatchEvent(new KeyboardEvent("keydown", { key: "Home", bubbles: true })); await pause(); ensure(matches("changes"), "Home must select the first repository tab");
    host.querySelector<HTMLButtonElement>(".repository-tab-pin")!.click(); await pause(); ensure(store.isRepositoryPagePinned("changes") && row("changes"), "Current tool could not be pinned to the sidebar");
    tab("branches").click(); await pause(); store.moveWorkspaceHistory(-1); await pause(); ensure(matches("changes"), "Back must restore a repository tab"); store.moveWorkspaceHistory(1); await pause(); ensure(matches("branches"), "Forward must restore a repository tab");
    host.querySelector<HTMLButtonElement>(".workspace-nav-customize")!.click(); await pause();
    const choices = [...host.querySelectorAll<HTMLButtonElement>('.workspace-nav-customization [role="checkbox"]')]; ensure(choices.length === 6, "Sidebar customization omitted repository tools");
    choices[2].click(); await pause(); ensure(row("branches") && store.isRepositoryPagePinned("branches"), "Sidebar customization did not add the chosen tool");
    row("changes")!.click(); await pause(); ensure(matches("changes") && row("changes")?.getAttribute("aria-current") === "page", "Pinned shortcut did not open its repository tab");
    host.querySelector<HTMLButtonElement>(`.workspace-nav-unpin[aria-label="${t("Remove shortcut")}: ${t("Changes")}"]`)!.click(); await pause(); ensure(!row("changes") && matches("changes"), "Removing a shortcut must retain the active workspace");
    host.querySelector<HTMLButtonElement>(".workspace-nav-customize")!.click();
    const settingsButton = [...host.querySelectorAll<HTMLButtonElement>(".workspace-nav-footer button")][0]; settingsButton.click(); ensure(opened === 1, "Settings footer did not open preferences");
    const input = host.querySelector<HTMLInputElement>(".workspace-nav-search input")!;
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "k", ctrlKey: true, bubbles: true })); ensure(document.activeElement === input, "Page search shortcut did not focus navigation");
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, t("Rebase")); input.dispatchEvent(new Event("input", { bubbles: true })); await pause();
    ensure(host.querySelectorAll(".workspace-nav-scroll .workspace-nav-item").length === 1 && row("rebase"), "Page search must find tools that are not pinned");
    row("rebase")!.click(); await pause(); ensure(matches("rebase"), "Search did not open the unpinned repository tool");
    host.querySelector<HTMLButtonElement>(`button[aria-label="${t("Clear search")}"]`)!.click(); await pause();
    store.target = { provider: "gitlab", host: "gitlab.example.com", path: "demo/repo", remote: "origin" }; store.changed(); await pause();
    const navText = host.querySelector("nav")?.textContent; ensure(["Merge requests", "Pipelines", "Groups", "Snippets"].every((value) => navText?.includes(t(value))), "Provider-specific menu names were not applied");
    return [true, "One Repository entry, six work tabs, pin/unpin customization, keyboard navigation, per-tab Back/Forward, unpinned-tool search, settings and GitLab labels"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); settings.set("navigationToolsExpanded", expanded); settings.set("pinnedRepositoryPages", pinned); settings.set("workspaceDestinations", savedDestinations); settings.set("workspaceRepositorySections", savedSections); }
}
