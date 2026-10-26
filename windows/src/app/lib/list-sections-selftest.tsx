import { createRoot } from "react-dom/client";
import type { RepoTarget } from "@/entities/git";
import type { RequestScope } from "@/entities/hosting";
import { RepoStore } from "@/entities/repo";
import { PullRequestSection } from "@/widgets/sidebar";
import { t } from "@/shared/i18n";

const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 40));

/** The pull request list's search row, filter menu and page links, with the server calls replaced. */
export async function listSectionsSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div"); host.style.cssText = "position:fixed;left:-10000px;top:0;width:320px;height:700px"; document.body.append(host);
  let root = createRoot(host);
  const store = new RepoStore(), target: RepoTarget = { provider: "github", host: "github.com", path: "fixture/repo", remote: "origin" };
  const searches: [RequestScope, string][] = [];
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const type = (input: HTMLInputElement, value: string) => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value); input.dispatchEvent(new Event("input", { bubbles: true })); };
  try {
    store.path = "C:/fixture/list-sections"; store.target = target; store.headBranch = "topic";
    store.pullRequests = [{ number: 5, title: "Fixture request", body: "", author: "fixture", source: "topic", target: "main", headSHA: null, url: "https://github.com/fixture/repo/pull/5", isDraft: false, fromFork: false, updated: null }];
    store.prState = { kind: "loaded" };
    store.loadPullRequests = async () => {};
    store.filterPullRequests = async (scope, search) => { searches.push([scope, search]); store.requestQuery = { scope, search, page: 1 }; store.pullRequests = []; store.changed(); };
    root.render(<PullRequestSection store={store} target={target} openSettings={() => {}} />); await pause();
    const field = host.querySelector<HTMLInputElement>(`.list-search-field input[aria-label="${t("Search pull requests")}"]`);
    ensure(field && !host.querySelector("select"), "The list must have one search field and no state dropdown");
    ensure(host.querySelector(".side-head")?.textContent?.includes(t("Pull requests")), "The header is not the translated title");
    type(field!, "needle"); await pause();
    field!.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })); await pause();
    ensure(searches.at(-1)?.join() === "open,needle", `Enter did not search: ${JSON.stringify(searches)}`);
    ensure(host.textContent?.includes(t("No pull requests match this filter.")), "The empty text does not fit the filter");
    host.querySelector<HTMLButtonElement>(".list-search-clear")!.click(); await pause();
    ensure(searches.at(-1)?.join() === "open," && field!.value === "", "Clearing did not search again");
    const filter = host.querySelector<HTMLButtonElement>(".list-filter-button")!;
    ensure(!filter.classList.contains("on"), "The filter icon must stay plain on Open");
    filter.click(); await pause();
    const merged = [...document.querySelectorAll<HTMLElement>(".menu .menu-item")].find((item) => item.textContent?.trim() === t("Merged"));
    ensure(merged && document.querySelectorAll(".menu .menu-item").length === 5, "The filter menu must offer five choices");
    merged!.click(); await pause();
    ensure(searches.at(-1)?.join() === "merged," && filter.classList.contains("on"), "Choosing a filter did not search or fill the icon");
    store.pullRequests = [{ number: 5, title: "Fixture request", body: "", author: "fixture", source: "topic", target: "main", headSHA: null, url: "https://github.com/fixture/repo/pull/5", isDraft: false, fromFork: false, updated: null }]; store.changed(); await pause();
    host.querySelector<HTMLButtonElement>(`button[aria-label="${t("Open in Pull requests")}"]`)!.click(); await pause();
    ensure(store.destination === "pullRequests", "The header's page icon did not open the Pull requests page");
    store.navigate("repository");
    root.unmount(); host.replaceChildren(); root = createRoot(host);
    root.render(<PullRequestSection store={store} target={target} openSettings={() => {}} onPage />); await pause();
    ensure(!host.querySelector(".side-head .chev") && !host.querySelector(`button[aria-label="${t("Open in Pull requests")}"]`), "On the page the list must not fold or link to itself");
    return [true, "One search row with clear, Enter and a five-choice filter menu that fills its icon; translated header and filter-aware empty text; header link to the page; fixed list on the page"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); }
}
