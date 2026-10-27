import { createRoot } from "react-dom/client";
import type { PullRequest, RepoTarget } from "@/entities/git";
import { type IssueScope, type RequestScope, workStateTitle } from "@/entities/hosting";
import { RepoStore } from "@/entities/repo";
import { IssueListSection, PullRequestSection } from "@/widgets/sidebar";
import { t } from "@/shared/i18n";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 40));

/**
 * The pull request and issue lists: search and filter on their pages; in the repository sidebar only a caption for
 * an active filter and two header icons. Server calls are replaced.
 */
export async function listSectionsSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div"); host.style.cssText = "position:fixed;left:-10000px;top:0;width:320px;height:700px"; document.body.append(host);
  let root = createRoot(host);
  const store = new RepoStore(), target: RepoTarget = { provider: "github", host: "github.com", path: "fixture/repo", remote: "origin" };
  const request: PullRequest = { number: 5, title: "Fixture request", body: "", author: "fixture", source: "topic", target: "main", headSHA: null, url: "https://github.com/fixture/repo/pull/5", isDraft: false, fromFork: false, updated: null };
  const searches: [RequestScope, string][] = [], issueSearches: [IssueScope, string][] = [];
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const type = (input: HTMLInputElement, value: string) => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value); input.dispatchEvent(new Event("input", { bubbles: true })); };
  const remount = async (node: React.ReactNode) => { root.unmount(); host.replaceChildren(); root = createRoot(host); root.render(node); await pause(); };
  const iconButton = (label: string) => host.querySelector<HTMLButtonElement>(`.side-head button[aria-label="${label}"]`);
  try {
    store.path = "C:/fixture/list-sections"; store.target = target; store.headBranch = "topic";
    store.pullRequests = [request]; store.prState = { kind: "loaded" };
    store.loadPullRequests = async () => {};
    store.filterPullRequests = async (scope, search) => { searches.push([scope, search]); store.requestQuery = { scope, search, page: 1 }; store.pullRequests = []; store.changed(); };
    // the Pull requests page: one search row with a filter menu, refresh and no link to itself
    await remount(<PullRequestSection store={store} target={target} openSettings={() => {}} onPage />);
    const field = host.querySelector<HTMLInputElement>(`.list-search-field input[aria-label="${t("Search pull requests")}"]`);
    ensure(field && !host.querySelector("select"), "The page list must have one search field and no state dropdown");
    ensure(host.querySelector(".side-head")?.textContent?.includes(t("Pull requests")), "The header is not the translated title");
    ensure(iconButton(t("Refresh list")) && !iconButton(t("Open in Pull requests")) && !host.querySelector(".side-head .chev"), "The page header must refresh, not link to itself or fold");
    type(field!, "needle"); await pause();
    field!.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })); await pause();
    ensure(searches.at(-1)?.join() === "open,needle", `Enter did not search: ${JSON.stringify(searches)}`);
    ensure(host.textContent?.includes(t("No pull requests match this filter.")), "The empty text does not fit the filter");
    host.querySelector<HTMLButtonElement>(".list-search-clear")!.click(); await pause();
    ensure(searches.at(-1)?.join() === "open," && field!.value === "", "Clearing did not search again");
    const filter = host.querySelector<HTMLButtonElement>(".list-filter-button")!;
    ensure(!filter.classList.contains("on"), "The filter icon must stay plain on Open");
    filter.click(); await pause();
    const merged = [...document.querySelectorAll<HTMLElement>(".menu .menu-item")].find((item) => item.textContent?.trim() === workStateTitle("merged"));
    ensure(merged && document.querySelectorAll(".menu .menu-item").length === 5, "The filter menu must offer five choices");
    merged!.click(); await pause();
    ensure(searches.at(-1)?.join() === "merged," && filter.classList.contains("on"), "Choosing a filter did not search or fill the icon");
    // the repository sidebar: no search row, a caption for the active filter, the page link and new request only
    store.requestQuery = { scope: "merged", search: "fix", page: 1 }; store.pullRequests = [request];
    await remount(<PullRequestSection store={store} target={target} openSettings={() => {}} />);
    ensure(!host.querySelector(".list-search-field") && !host.querySelector(".list-filter-button"), "The sidebar must not show the search row");
    ensure(host.querySelectorAll(".side-head button").length === 2 && iconButton(t("Open in Pull requests")) && !iconButton(t("Refresh list")), "The sidebar header must keep only the page link and the new request button");
    const caption = host.querySelector(".list-filter-caption");
    ensure(caption?.textContent?.includes(t("Filtered: {0}", `${workStateTitle("merged")} · “fix”`)), `The filter caption is missing: ${caption?.textContent}`);
    host.querySelector<HTMLButtonElement>(`.list-filter-caption button[aria-label="${t("Clear filter")}"]`)!.click(); await pause();
    ensure(searches.at(-1)?.join() === "open," && !host.querySelector(".list-filter-caption"), "Clearing the caption did not go back to open requests");
    iconButton(t("Open in Pull requests"))!.click(); await pause();
    ensure(store.destination === "pullRequests", "The header's page icon did not open the Pull requests page");
    store.navigate("repository");
    // the issue list in the sidebar shows the search it was loaded with, not unsent typing
    store.prepareIssues = async () => {};
    store.filterIssues = async (scope, search = store.issueSearch) => { issueSearches.push([scope, search]); store.issueScope = scope; store.issueSearch = search; store.issueLoadedSearch = search; store.changed(); };
    store.issueState = { kind: "loaded" }; store.issueScope = "closed"; store.issueLoadedSearch = "crash"; store.issueSearch = "unsent";
    await remount(<IssueListSection store={store} openSettings={() => {}} />);
    ensure(!host.querySelector(".list-search-field") && host.querySelectorAll(".side-head button").length === 2 && iconButton(t("Open in Issues")) && iconButton(t("New issue")), "The issue sidebar must keep only the page link and new issue");
    ensure(host.querySelector(".list-filter-caption")?.textContent?.includes(t("Filtered: {0}", `${workStateTitle("closed")} · “crash”`)), "The issue caption must show the loaded search");
    host.querySelector<HTMLButtonElement>(".list-filter-caption button")!.click(); await pause();
    ensure(issueSearches.at(-1)?.join() === "open," && !host.querySelector(".list-filter-caption"), "Clearing the issue caption did not go back to open issues");
    return [true, "Page: one search row with clear, Enter and a five-choice filter menu, refresh and no self link; sidebar: no search row, a filter caption that clears back to open, only the page link and new buttons, for pull requests and issues"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); }
}
