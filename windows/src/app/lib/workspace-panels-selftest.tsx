import { createRoot } from "react-dom/client";
import type { ReactNode } from "react";
import { RepoStore } from "@/entities/repo";
import { accounts } from "@/entities/hosting";
import { AccountWorkspacePanel } from "@/pages/repo";
import { WorkspaceHomePanel, IssuesWorkspacePanel, ActionsWorkspacePanel } from "@/widgets/workspace-panels";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
const pause = () => new Promise<void>((resolve) => setTimeout(resolve, 60));
/** Exercise actual page controls with fake servers, never real accounts or repository mutations. */
export async function workspacePanelsSelfTest(): Promise<[boolean, string]> {
  const host = document.createElement("div");
  host.hidden = true;
  document.body.append(host);
  let root = createRoot(host);
  const store = new RepoStore(),
    original = { http: ipc.http, writeText: ipc.writeText, ciLog: ipc.ciLog, token: accounts.token, accounts: accounts.accounts, section: settings.get("accountPageSection", "inbox") };
  let copies = "", writes = 0, mentions = 0, releases = 0;
  const profile = { id: "workspace-fixture", provider: "github" as const, server: "https://github.com", username: "fixture", name: null, avatarURL: null };
  const issue = { number: 7, title: "Fixture issue", body: "Fixture body", state: "open", html_url: "https://github.com/fixture/repo/issues/7", user: { login: "fixture" } };
  const check = (value: unknown, message: string) => { if (!value) throw new Error(message); };
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
    store.ci.jobs.set(1, [{ id: 9, name: "fixture build", status: "success", stage: "", url: "https://github.com/fixture/repo/actions/jobs/9", allowFailure: false, duration: 1 }]);
    ipc.http = async (method, url) => {
      if (method !== "GET") writes++;
      if (url.includes("/search/repositories?")) return { status: 200, body: JSON.stringify({ items: [{ full_name: "fixture/remote", clone_url: "https://github.com/fixture/remote.git", private: false }], total_count: 1 }) };
      if (url.includes("/search/issues?")) return { status: 200, body: JSON.stringify({ items: [{ id: 1, number: 1, title: "Fixture global work", html_url: "https://github.com/fixture/other/pull/1", repository_url: "https://api.github.com/repos/fixture/other", state: "open" }], total_count: 1 }) };
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
    // Account: Inbox, My work, Releases, Projects and Organizations on one page
    settings.set("accountPageSection", "inbox");
    await mount(<AccountWorkspacePanel store={store} openSettings={() => {}} />);
    check(host.querySelectorAll(".account-page-sections .segmented button").length === 5, "Account page must offer its five sections");
    check(mentions > 0 && host.textContent?.includes("Fixture mention"), "Inbox did not query mentions");
    check(!host.querySelector('[role="dialog"]'), "Inbox is still a modal");
    host.querySelector<HTMLButtonElement>(".inbox-item")!.click();
    await pause();
    check(host.textContent?.includes("Fixture comment"), "Inbox conversation missing");
    await click("Mark as read");
    await click("My work");
    await pause();
    check(host.textContent?.includes("Fixture pull request") && host.textContent?.includes("Fixture issue"), "My work summaries missing");
    await click("Releases");
    check(await (async () => { for (let i = 0; i < 40 && !host.textContent?.includes("Fixture release"); i++) await pause(); return host.textContent?.includes("Fixture release"); })(), "Releases section did not load the hub");
    check(releases > 0 && settings.get<string>("accountPageSection", "") === "releases", "The account section was not remembered");
    check([...host.querySelectorAll("button")].every((b) => b.textContent?.trim() !== t("Gists")), "Gists must be gone");
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
    await mount(<IssuesWorkspacePanel store={store} />);
    check(host.textContent?.includes("Fixture issue"), "Issues page missing server issues");
    await click("New issue");
    const title = host.querySelector<HTMLInputElement>("label input")!;
    await change(title, "Created fixture issue");
    await click("Save");
    check(writes === 2, "Issue create or mark-read writes did not reach the fixture server");
    check(host.textContent?.includes("Fixture comment"), "Created issue did not open its conversation");
    await click("Edit issue");
    const edit = host.querySelector<HTMLInputElement>("label input")!;
    await change(edit, "Edited fixture issue");
    await click("Save");
    check(writes === 3, "Issue edit did not reach the fixture server");
    reset();
    await mount(<ActionsWorkspacePanel store={store} />);
    await change(host.querySelector('select[aria-label="' + t("Job") + '"]')!, "9");
    await click("Load log");
    check(host.querySelector("pre")?.textContent?.includes("build passed"), "Job log preview missing");
    await click("Copy redacted log");
    check(copies.includes("[redacted]") && !copies.includes("private-secret") && !copies.includes("fixture-token"), "Copied log did not redact credentials");
    return [true, "Home welcome actions and remote clone, Account page with inbox mentions/read, my-work summaries, releases section and no gists, account-only work, issue create/edit/conversation and CI bounded redacted log passed"];
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
