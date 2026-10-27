import { createRoot } from "react-dom/client";
import type { ReactNode } from "react";
import { RepoStore } from "@/entities/repo";
import { accounts } from "@/entities/hosting";
import { gitch } from "@/entities/gitch";
import {
  WorkspaceHomePanel,
  RepositoryLibraryPanel,
  WorkInboxPanel,
  MyWorkPanel,
  IssuesWorkspacePanel,
  ActionsWorkspacePanel,
  OperationsWorkspacePanel,
} from "@/widgets/workspace-panels";
import { ipc } from "@/shared/api";
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
    original = {
      http: ipc.http,
      writeText: ipc.writeText,
      ciLog: ipc.ciLog,
      token: accounts.token,
      accounts: accounts.accounts,
      doctor: gitch.doctor,
    };
  const requests: { method: string; path: string; page: string }[] = [];
  let copies = "",
    writes = 0,
    doctors = 0,
    mentions = 0,
    projectReads = 0;
  const profile = {
    id: "workspace-fixture",
    provider: "github" as const,
    server: "https://github.com",
    username: "fixture",
    name: null,
    avatarURL: null,
  };
  const issue = {
    number: 7,
    title: "Fixture issue",
    body: "Fixture body",
    state: "open",
    html_url: "https://github.com/fixture/repo/issues/7",
    user: { login: "fixture" },
  };
  const check = (value: unknown, message: string) => {
    if (!value) throw new Error(message);
  };
  const until = async (test: () => boolean) => {
    const deadline = Date.now() + 3500;
    while (!test() && Date.now() < deadline) await pause();
    return test();
  };
  const writeDetails = () => `writes=${writes}; requests=${JSON.stringify(requests.filter((request) => request.method !== "GET"))}; errors=${[...host.querySelectorAll('[role="alert"], .error-text')].map((element) => element.textContent).join(" | ")}`;
  const click = async (label: string) => {
    const b = [...host.querySelectorAll<HTMLButtonElement>("button")].find(
      (b) => b.textContent?.trim() === t(label) && !b.disabled,
    );
    check(b, `Missing enabled button: ${label}`);
    b!.click();
    await pause();
  };
  const mount = async (node: ReactNode) => {
    root.render(node);
    await pause();
    await pause();
  };
  const reset = () => {
    root.unmount();
    host.replaceChildren();
    root = createRoot(host);
  };
  const change = async (
    element: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement,
    value: string,
  ) => {
    const prototype =
      element instanceof HTMLSelectElement
        ? HTMLSelectElement.prototype
        : element instanceof HTMLTextAreaElement
          ? HTMLTextAreaElement.prototype
          : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(
      element,
      value,
    );
    element.dispatchEvent(
      new Event(element instanceof HTMLSelectElement ? "change" : "input", {
        bubbles: true,
      }),
    );
    await pause();
  };
  try {
    ipc.writeText = async () => {};
    accounts.accounts = [profile];
    accounts.token = async () => "fixture-token";
    store.path = "C:/fixture/repo";
    store.target = {
      provider: "github",
      host: "github.com",
      remote: "origin",
      path: "fixture/repo",
    };
    store.headBranch = "topic";
    Object.defineProperty(store, "hostingAccount", { get: () => profile });
    store.copy = (text) => {
      copies = text;
    };
    store.ci.load = async () => {};
    store.ci.jobs.set(1, [
      {
        id: 9,
        name: "fixture build",
        status: "success",
        stage: "",
        url: "https://github.com/fixture/repo/actions/jobs/9",
        allowFailure: false,
        duration: 1,
      },
    ]);
    ipc.http = async (method, url, _headers, body) => {
      requests.push({ method, path: new URL(url).pathname, page: host.querySelector("h1")?.textContent ?? "" });
      const projectQuery = workspaceFixtureProjectQuery(method, url, body);
      if (projectQuery) {
        check(projectQuery.owner === profile.username, "Home project query used the wrong account");
        projectReads++;
        return { status: 200, body: JSON.stringify({ data: { user: { projectsV2: { nodes: [], pageInfo: { hasNextPage: false, endCursor: null } } } } }) };
      }
      if (method !== "GET") writes++;
      if (url.includes("/search/repositories?"))
        return {
          status: 200,
          body: JSON.stringify({
            items: [
              {
                full_name: "fixture/remote",
                clone_url: "https://github.com/fixture/remote.git",
                private: false,
              },
            ],
            total_count: 1,
          }),
        };
      if (url.includes("/search/issues?"))
        return {
          status: 200,
          body: JSON.stringify({
            items: [
              {
                id: 1,
                number: 1,
                title: "Fixture global work",
                html_url: "https://github.com/fixture/other/pull/1",
                repository_url: "https://api.github.com/repos/fixture/other",
                state: "open",
              },
            ],
            total_count: 1,
          }),
        };
      if (url.endsWith("/pulls/1"))
        return {
          status: 200,
          body: JSON.stringify({
            number: 1,
            title: "Fixture pull request",
            body: "Details",
            user: { login: "fixture" },
            head: {
              ref: "topic",
              sha: "a".repeat(40),
              repo: { full_name: "fixture/repo" },
            },
            base: { ref: "main" },
            html_url: "https://github.com/fixture/repo/pull/1",
            state: "open",
          }),
        };
      if (url.includes("/notifications?")) {
        mentions++;
        return {
          status: 200,
          body: JSON.stringify([
            {
              id: "44",
              reason: "mention",
              unread: true,
              subject: {
                title: "Fixture mention",
                url: "https://api.github.com/repos/fixture/repo/issues/7",
                type: "Issue",
              },
              repository: { full_name: "fixture/repo" },
            },
          ]),
        };
      }
      if (url.includes("/comments?"))
        return {
          status: 200,
          body: JSON.stringify([
            { id: 1, body: "Fixture comment", user: { login: "reviewer" } },
          ]),
        };
      if (url.includes("/issues?"))
        return { status: 200, body: JSON.stringify([issue]) };
      return { status: 200, body: JSON.stringify(issue) };
    };
    ipc.ciLog = async () => ({
      body: "build passed\nAuthorization: Bearer private-secret\nfixture-token",
      truncated: false,
    });
    gitch.doctor = async () => {
      doctors++;
      return {
        version: 1,
        problems: 0,
        checks: [{ level: "OK", section: "Fixture", message: "Ready" }],
      };
    };
    await mount(<WorkspaceHomePanel store={store} />);
    check(await until(() => projectReads === 1 && [...host.querySelectorAll("button")].some((button) => button.textContent?.trim() === t("Open project workspace"))), "Home project catalog did not finish loading");
    check(!host.querySelector(".planning-error"), "Home project catalog returned a hidden fixture error");
    check(writes === 0, `Home performed an unexpected mutation: ${writeDetails()}`);
    check(
      host.textContent?.includes("C:/fixture/repo"),
      "Home missing local repository status",
    );
    await click("Review changes");
    check(store.destination === "repository" && store.repositorySection === "changes", "Home did not navigate to Changes");
    reset();
    await mount(<RepositoryLibraryPanel store={store} />);
    check(
      host.textContent?.includes(t("Recent local repositories")),
      "Local repository section missing",
    );
    await change(host.querySelector("select")!, profile.id);
    await change(host.querySelector("input")!, "fixture remote");
    await click("Search");
    check(
      host.textContent?.includes("fixture/remote"),
      "Remote server search did not render",
    );
    await click("Clone…");
    check(
      store.sheet?.kind === "clone" &&
        store.sheet.url === "https://github.com/fixture/remote.git",
      "Remote Clone did not preserve URL",
    );
    store.sheet = null;
    reset();
    await mount(<WorkInboxPanel store={store} />);
    check(
      mentions > 0 && host.textContent?.includes("Fixture mention"),
      "Inbox did not query mentions",
    );
    check(!host.querySelector('[role="dialog"]'), "Inbox is still a modal");
    host.querySelector<HTMLButtonElement>(".inbox-item")!.click();
    await pause();
    check(
      host.textContent?.includes("Fixture comment"),
      "Inbox conversation missing",
    );
    await click("Mark as read");
    check(await until(() => writes === 1 && !store.inboxBusy && store.inboxDetail?.item.unread === false), `Mark-read mutation did not finish: ${writeDetails()}`);
    reset();
    await mount(<MyWorkPanel store={store} />);
    check(
      host.textContent?.includes("Fixture pull request") &&
        host.textContent?.includes("Fixture issue"),
      "My work summaries missing",
    );
    reset();
    const repositoryTarget = store.target;
    store.target = null;
    await mount(<MyWorkPanel store={store} />);
    check(
      host.textContent?.includes(
        t("Select an account to load work across its repositories."),
      ),
      "Global work did not require an explicit account",
    );
    await change(
      host.querySelector(
        'select[aria-label="' + t("Account and server") + '"]',
      )!,
      profile.id,
    );
    check(
      host.textContent?.includes("Fixture global work") &&
        host.textContent?.includes("github.com/fixture/other"),
      "No-repository account work missing",
    );
    await click("Assigned requests");
    check(
      host.textContent?.includes("Fixture global work"),
      "Global assigned requests missing",
    );
    reset();
    await mount(<WorkInboxPanel store={store} />);
    await change(
      host.querySelector(
        'select[aria-label="' + t("Account and server") + '"]',
      )!,
      profile.id,
    );
    check(
      host.textContent?.includes("Fixture mention") &&
        host.textContent?.includes("github.com/fixture/repo"),
      "No-repository account inbox missing",
    );
    reset();
    store.target = repositoryTarget;
    await mount(<IssuesWorkspacePanel store={store} />);
    check(
      host.textContent?.includes("Fixture issue"),
      "Issues page missing server issues",
    );
    await click("New issue");
    const title = host.querySelector<HTMLInputElement>("label input")!;
    await change(title, "Created fixture issue");
    await click("Save");
    check(
      await until(() => writes === 2 && host.textContent?.includes("Fixture comment") === true),
      `Issue create or mark-read writes did not reach the fixture server: ${writeDetails()}`,
    );
    check(
      host.textContent?.includes("Fixture comment"),
      "Created issue did not open its conversation",
    );
    await click("Edit issue");
    const edit = host.querySelector<HTMLInputElement>("label input")!;
    await change(edit, "Edited fixture issue");
    await click("Save");
    check(await until(() => writes === 3 && ![...host.querySelectorAll("button")].some((button) => button.textContent?.trim() === t("Save"))), `Issue edit did not finish: ${writeDetails()}`);
    reset();
    await mount(<ActionsWorkspacePanel store={store} />);
    await change(
      host.querySelector('select[aria-label="' + t("Job") + '"]')!,
      "9",
    );
    await click("Load log");
    check(
      host.querySelector("pre")?.textContent?.includes("build passed"),
      "Job log preview missing",
    );
    await click("Copy redacted log");
    check(
      copies.includes("[redacted]") &&
        !copies.includes("private-secret") &&
        !copies.includes("fixture-token"),
      "Copied log did not redact credentials",
    );
    reset();
    await mount(<OperationsWorkspacePanel store={store} />);
    await click("Check setup");
    check(
      doctors === 1 && host.textContent?.includes("Ready"),
      "Tools diagnosis missing",
    );
    check(
      host.textContent?.includes(t("Find a command or task")),
      "Command guide missing from Tools",
    );
    return [
      true,
      `Home project catalog query=${projectReads} with zero mutations; Home/repositories/remote clone, embedded mentions/read, my-work summaries, exact create/read/edit mutations=${writes}, issue conversation, CI bounded redacted log and Tools diagnosis/guide controls passed`,
    ];
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
    gitch.doctor = original.doctor;
    store.ci.reset();
  }
}
