import { createRoot } from "react-dom/client";
import type { ReactNode } from "react";
import type { SheetKind } from "@/entities/git";
import { RepoStore } from "@/entities/repo";
import { accounts } from "@/entities/hosting";
import { AccountWorkspacePanel, WorkspaceContent } from "@/pages/repo";
import { WorkspaceHomePanel, ActionsWorkspacePanel } from "@/widgets/workspace-panels";
import { HostingHubPanel } from "@/widgets/hosting-hub";
import { IssueListSection } from "@/widgets/sidebar";
import { IssueEditorSheet } from "@/features/edit-issue";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { workspaceFixtureProjectQuery } from "./workspace-panels-fixture";
const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 60));
/** Exercise actual page controls with fake servers, never real accounts or repository mutations. */
export async function workspacePanelsSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div");
  host.hidden = true;
  document.body.append(host);
  let root = createRoot(host);
  const store = new RepoStore(),
    original = { http: ipc.http, writeText: ipc.writeText, ciLog: ipc.ciLog, token: accounts.token, accounts: accounts.accounts, section: settings.get("accountPageSection", "inbox") };
  const requests: { method: string; path: string }[] = [];
  let copies = "", writes = 0, mentions = 0, releases = 0, projectReads = 0;
  const profile = { id: "workspace-fixture", provider: "github" as const, server: "https://github.com", username: "fixture", name: null, avatarURL: null };
  const issue = { number: 7, title: "Fixture issue", body: "Fixture body", state: "open", html_url: "https://github.com/fixture/repo/issues/7", user: { login: "fixture" } };
  const check = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  const until = async (test: () => boolean) => {
    const deadline = Date.now() + 3500;
    while (!test() && Date.now() < deadline) await pause();
    return test();
  };
  const writeDetails = () => `writes=${writes}; requests=${JSON.stringify(requests.filter((request) => request.method !== "GET"))}; errors=${[...host.querySelectorAll('[role="alert"], .error-text')].map((element) => element.textContent).join(" | ")}`;
  // read through a function: buttons set the sheet behind TypeScript's narrowing
  const sheet = (): SheetKind | null => store.sheet;
  const click = async (label: string) => {
    const b = [...host.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent?.trim() === t(label) && !b.disabled);
    check(b, `Missing enabled button: ${label}`);
    b!.click();
    await pause();
  };
  const mount = async (node: ReactNode) => { root.render(node); await pause(); await pause(); };
  const reset = () => { root.unmount(); host.replaceChildren(); root = createRoot(host); };
  const change = async (element: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement, value: string) => {
    const prototype = element instanceof HTMLSelectElement ? HTMLSelectElement.prototype : element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(element, value);
    element.dispatchEvent(new Event(element instanceof HTMLSelectElement ? "change" : "input", { bubbles: true }));
    await pause();
  };
  try {
    ipc.writeText = async () => {};
    accounts.accounts = [profile];
    accounts.token = async () => "fixture-token";
    store.path = "C:/fixture/repo";
    store.target = { provider: "github", host: "github.com", remote: "origin", path: "fixture/repo" };
    store.headBranch = "topic";
    Object.defineProperty(store, "hostingAccount", { get: () => profile });
    store.copy = (text) => { copies = text; };
    store.ci.load = async () => {};
    store.ci.loadJobs = async () => {};
    store.ci.jobs.set(1, [{ id: 9, name: "fixture build", status: "success", stage: "", url: "https://github.com/fixture/repo/actions/jobs/9", allowFailure: false, duration: 1 }]);
    ipc.http = async (method, url, _headers, body) => {
      requests.push({method, path: new URL(url).pathname});
      const projectQuery = workspaceFixtureProjectQuery(method, url, body);
      if (projectQuery) {
        check(projectQuery.owner === profile.username, "Home project query used the wrong account");
        projectReads++;
        return {status: 200, body: JSON.stringify({data: {user: {projectsV2: {nodes: [], pageInfo: {hasNextPage: false, endCursor: null}}}}})};
      }
      if (method !== "GET") writes++;
      if (url.includes("/search/repositories?")) return { status: 200, body: JSON.stringify({ items: [{ full_name: "fixture/remote", clone_url: "https://github.com/fixture/remote.git", private: false }], total_count: 1 }) };
      if (url.includes("/search/issues?")) return { status: 200, body: JSON.stringify({ items: [{ id: 1, number: 1, title: "Fixture global work", html_url: "https://github.com/fixture/other/pull/1", repository_url: "https://api.github.com/repos/fixture/other", state: "open" }], total_count: 1 }) };
      if (url.includes("/pulls?")) return { status: 200, body: JSON.stringify([{ number: 1, title: "Fixture pull request", body: "Details", user: { login: "fixture" }, requested_reviewers: [{ login: "fixture" }], head: { ref: "topic", sha: "a".repeat(40), repo: { full_name: "fixture/repo" } }, base: { ref: "main" }, html_url: "https://github.com/fixture/repo/pull/1", state: "open" }]) };
      if (url.endsWith("/pulls/1")) return { status: 200, body: JSON.stringify({ number: 1, title: "Fixture pull request", body: "Details", user: { login: "fixture" }, head: { ref: "topic", sha: "a".repeat(40), repo: { full_name: "fixture/repo" } }, base: { ref: "main" }, html_url: "https://github.com/fixture/repo/pull/1", state: "open" }) };
      if (url.includes("/notifications?")) { mentions++; return { status: 200, body: JSON.stringify([{ id: "44", reason: "mention", unread: true, subject: { title: "Fixture mention", url: "https://api.github.com/repos/fixture/repo/issues/7", type: "Issue" }, repository: { full_name: "fixture/repo" } }]) }; }
      if (url.includes("/releases?")) { releases++; return { status: 200, body: JSON.stringify([{ id: 3, name: "Fixture release", tag_name: "v1.0", body: "Notes", draft: false, html_url: "https://github.com/fixture/repo/releases/tag/v1.0", assets: [] }]) }; }
      if (url.includes("/comments?")) return { status: 200, body: JSON.stringify([{ id: 1, body: "Fixture comment", user: { login: "reviewer" } }]) };
      if (url.includes("/issues?")) return { status: 200, body: JSON.stringify([issue]) };
      return { status: 200, body: JSON.stringify(issue) };
    };
    ipc.ciLog = async () => ({ body: "build passed\nAuthorization: Bearer private-secret\nfixture-token", truncated: false });
    // Home: the welcome actions, recents and the search of repositories on a server
    await mount(<WorkspaceHomePanel store={store} />);
    check(await until(() => projectReads === 1 && [...host.querySelectorAll("button")].some((button) => button.textContent?.trim() === t("Open project workspace"))), "Home project catalog did not finish loading");
    check(!host.querySelector(".planning-error"), "Home project catalog returned a hidden fixture error");
    check(writes === 0, `Home performed an unexpected mutation: ${writeDetails()}`);
    check(host.querySelector(".welcome") && [...host.querySelectorAll("button")].some((b) => b.textContent?.trim() === t("Open repository…")), "Home missing the welcome actions");
    check(host.textContent?.includes(t("Recent repositories")) && host.textContent?.includes(t("Repositories on a server")), "Home missing recents or the server search");
    await change(host.querySelector(".remote-search select")!, profile.id);
    await change(host.querySelector(".remote-search input")!, "fixture remote");
    await click("Search");
    check(host.textContent?.includes("fixture/remote"), "Remote server search did not render");
    await click("Clone…");
    check(store.sheet?.kind === "clone" && store.sheet.url === "https://github.com/fixture/remote.git", "Remote Clone did not preserve URL");
    store.sheet = null;
    reset();
    // Account: Inbox, My work and Organizations on one page; Releases and Projects have pages of their own
    settings.set("accountPageSection", "inbox");
    await mount(<AccountWorkspacePanel store={store} openSettings={() => {}} />);
    check(host.querySelectorAll(".account-page-sections .segmented button").length === 3, "Account page must offer its three sections");
    check([...host.querySelectorAll(".account-page-sections button")].every((b) => b.textContent?.trim() !== t("Projects") && b.textContent?.trim() !== t("Releases")), "Releases and Projects must not be account sections");
    check(!host.querySelector("h1"), "Account sections must not show a large page title");
    check(mentions > 0 && host.textContent?.includes("Fixture mention"), "Inbox did not query mentions");
    check(!host.querySelector('[role="dialog"]'), "Inbox is still a modal");
    host.querySelector<HTMLButtonElement>(".inbox-item")!.click();
    await pause();
    check(host.textContent?.includes("Fixture comment"), "Inbox conversation missing");
    await click("Mark as read");
    check(await until(() => writes === 1 && !store.inboxBusy && store.inboxDetail?.item.unread === false), `Mark-read mutation did not finish: ${writeDetails()}`);
    await click("My work");
    await pause();
    check(await until(() => host.textContent?.includes("Fixture pull request") === true && host.textContent?.includes("Fixture issue") === true), `My work summaries missing: ${writeDetails()}`);
    check(settings.get<string>("accountPageSection", "") === "myWork", "The account section was not remembered");
    check([...host.querySelectorAll("button")].every((b) => b.textContent?.trim() !== t("Gists")), "Gists must be gone");
    reset();
    // the Releases page: the hub's release list for the repository
    await mount(<HostingHubPanel store={store} section="releases" onClone={() => {}} />);
    check(await (async () => { for (let i = 0; i < 40 && !host.textContent?.includes("Fixture release"); i++) await pause(); return host.textContent?.includes("Fixture release"); })() && releases > 0, "The Releases page did not load the hub");
    reset();
    const repositoryTarget = store.target;
    store.target = null;
    settings.set("accountPageSection", "myWork");
    await mount(<AccountWorkspacePanel store={store} openSettings={() => {}} />);
    check(host.textContent?.includes(t("Select an account to load work across its repositories.")), "Global work did not require an explicit account");
    await change(host.querySelector('select[aria-label="' + t("Account and server") + '"]')!, profile.id);
    check(host.textContent?.includes("Fixture global work") && host.textContent?.includes("github.com/fixture/other"), "No-repository account work missing");
    await click("Assigned requests");
    check(host.textContent?.includes("Fixture global work"), "Global assigned requests missing");
    reset();
    store.target = repositoryTarget;
    store.path = "C:/fixture/repo";
    // the repository sidebar's issue list: a row opens the Issues page with that issue
    store.navigate("repository");
    await mount(<IssueListSection store={store} openSettings={() => {}} />);
    check(host.querySelector('.side-row[data-issue="7"]')?.textContent?.includes("Fixture issue"), "The sidebar issue list did not load");
    host.querySelector<HTMLElement>('.side-row[data-issue="7"]')!.click(); await pause();
    check(store.destination === "issues" && store.inboxDetail?.item.number === 7, "A sidebar issue did not open on the Issues page");
    reset();
    // the page keeps the issue that was just opened and shows it like a pull request
    await mount(<WorkspaceContent store={store} openSettings={() => {}} />);
    check(host.querySelector(".workspace-pr-list .side-row[data-issue=\"7\"]") && !host.querySelector(".workspace-pr-list .side-head .chev"), "The Issues page must show the fixed shared list");
    check(host.textContent?.includes(t("Issue #{0}", 7)) && host.textContent?.includes("Fixture comment") && host.querySelector(".issue-detail .md"), "The opened issue was cleared or its Markdown conversation is missing");
    check(writes === 1, `Navigation performed an unexpected mutation: ${writeDetails()}`);
    const before = writes;
    const composer = host.querySelector<HTMLTextAreaElement>(`.issue-detail textarea[aria-label="${t("Comment")}"]`)!;
    await change(composer, "Fixture reply");
    await click("Comment");
    check(await until(() => writes === before + 1 && !store.inboxBusy), `The comment composer did not post: ${writeDetails()}`);
    await click("Close issue…");
    check(store.confirm?.destructive === false, "Closing an issue must ask first");
    store.confirm = null;
    // new and edited issues use the editor dialog
    host.querySelector<HTMLButtonElement>(`button[aria-label="${t("New issue")}"]`)!.click(); await pause();
    check(sheet()?.kind === "issueEditor" && (sheet() as { number?: number }).number === undefined, "New issue did not open the editor dialog");
    const dialog = document.createElement("div"); document.body.append(dialog);
    let editor = createRoot(dialog);
    const editIn = async (current: SheetKind | null, value: string) => {
      if (current?.kind !== "issueEditor") throw new Error("Missing issue editor");
      let closed = false;
      editor.render(<IssueEditorSheet store={store} close={() => { closed = true; }} number={current.number} title={current.title} body={current.body} />); await pause();
      await change(dialog.querySelector<HTMLInputElement>(`input[aria-label="${t("Title")}"]`)!, value);
      [...dialog.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent?.trim() === t("Save"))!.click();
      for (let i = 0; i < 40 && !closed; i++) await pause();
      editor.unmount(); editor = createRoot(dialog);
      return closed;
    };
    check(await editIn(sheet(), "Created fixture issue") && await until(() => writes === before + 2), `Creating an issue did not reach the fixture server: ${writeDetails()}`);
    store.sheet = null;
    await click("Edit issue");
    check(sheet()?.kind === "issueEditor" && (sheet() as { number?: number }).number === 7, "Edit issue did not open the editor dialog");
    check(await editIn(sheet(), "Edited fixture issue") && await until(() => writes === before + 3), `Editing an issue did not reach the fixture server: ${writeDetails()}`);
    store.sheet = null; dialog.remove();
    // opened from the repository screen, the page offers the way back; from another page it does not
    const back = () => host.querySelector<HTMLButtonElement>(`.page-header button[aria-label="${t("Back to the repository screen")}"]`);
    check(back()?.textContent?.includes(t("Repository")), "The Issues page opened from the repository screen must offer the way back");
    back()!.click(); await pause();
    check(store.destination === "repository" && !back(), "The back button did not return to the repository screen");
    store.navigate("compare"); store.navigate("issues"); await pause();
    check(!back(), "The back button must not show when another page opened Issues");
    reset();
    store.ci.pipelines = [{ id: 1, number: 12, name: "CI", title: "Fixture run", ref: "topic", sha: "a".repeat(40), status: "success", url: "https://github.com/fixture/repo/actions/runs/1", created: null, event: "push", actor: "fixture" }];
    await mount(<ActionsWorkspacePanel store={store} />);
    check(!host.querySelector("h1"), "Actions must not show a large page title");
    check(host.textContent?.includes(t("Select a run")), "Actions must ask for a run before showing one");
    // a row selects the run; a job shows its log beside the jobs
    host.querySelector<HTMLElement>('.ci-run[data-pipeline="1"]')!.click(); await pause(); await pause();
    check(store.ciSelected === 1 && host.querySelector(".ci-run-detail")?.textContent?.includes("Fixture run"), "Selecting a run did not show it");
    host.querySelector<HTMLElement>(".ci-job")!.click(); await pause(); await pause(); await pause();
    check(host.querySelector(".ci-log-text")?.textContent?.includes("build passed"), "Job log preview missing");
    host.querySelector<HTMLButtonElement>('button[aria-label="' + t("Copy redacted log") + '"]')!.click(); await pause();
    check(copies.includes("[redacted]") && !copies.includes("private-secret") && !copies.includes("fixture-token"), "Copied log did not redact credentials");
    store.ciSelected = null;
    check(writes === 4, `Unexpected mutation total: ${writeDetails()}`);
    return [true, `Home project catalog query=${projectReads} with zero mutations; exact read/comment/create/edit mutations=${writes}; Home welcome actions and remote clone, Account page with inbox mentions/read, my-work summaries, a Releases page and no gists, account-only work, sidebar issue opening the Issues page, issue detail with Markdown, composer, close confirmation and the create/edit dialog, and CI bounded redacted log passed`];
  } catch (error) {
    return [false, error instanceof Error ? error.message : String(error)];
  } finally {
    root.unmount();
    host.remove();
    ipc.http = original.http;
    ipc.writeText = original.writeText;
    ipc.ciLog = original.ciLog;
    accounts.token = original.token;
    accounts.accounts = original.accounts;
    settings.set("accountPageSection", original.section);
    store.ci.reset();
  }
}
