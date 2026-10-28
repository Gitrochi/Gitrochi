import type { ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { accounts } from "@/entities/hosting";
import type { RepoTarget } from "@/entities/git";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { HostingHubPanel } from "@/widgets/hosting-hub";

const pause = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
async function until(test: () => boolean) {
  const end = Date.now() + 3500;
  while (Date.now() < end) {
    if (test()) return true;
    await pause(20);
  }
  return false;
}
/** Actual React screens; all HTTP, account secrets and browser launches are isolated in memory. */
export async function hostingHubSelfTest(): Promise<[boolean, string]> {
  const original = {
    http: ipc.http,
    openUrl: ipc.openUrl,
    token: accounts.token,
    accounts: accounts.accounts,
  };
  const host = document.createElement("div");
  host.hidden = true;
  host.dataset.selftest = "hosting-hub";
  document.body.append(host);
  let root = createRoot(host);
  const writes: {
      method: string;
      url: string;
      body: Record<string, unknown>;
    }[] = [],
    details: string[] = [];
  const source = {
    path: "C:/hosting-hub-selftest",
    target: {
      provider: "github",
      host: "github.com",
      path: "team/repo",
      remote: "origin",
    } as RepoTarget,
    get hostingAccount() {
      return accounts.accounts[0] ?? null;
    },
  };
  const button = (label: string) =>
    [...host.querySelectorAll<HTMLButtonElement>("button")].find(
      (e) => e.textContent?.trim() === t(label) || e.getAttribute("aria-label") === t(label) || (label === "Confirm" && e.matches(".project-review-sheet footer > button:last-child, .project-create-review footer > button:last-child")),
    );
  const enter = (
    element: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement,
    value: string,
  ) => {
    const proto =
      element instanceof HTMLTextAreaElement
        ? HTMLTextAreaElement.prototype
        : element instanceof HTMLSelectElement
          ? HTMLSelectElement.prototype
          : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(element, value);
    element.dispatchEvent(
      new Event(element instanceof HTMLSelectElement ? "change" : "input", {
        bubbles: true,
      }),
    );
  };
  const ensure = (condition: boolean, message: string) => {
    if (!condition) throw new Error(message);
  };
  const mount = async (view: ReactNode) => {
    root.unmount();
    host.replaceChildren();
    root = createRoot(host);
    root.render(view);
    await pause(40);
  };
  let releaseName = "Desktop 1.0",
    projectEmpty = false,
    projectName = "Roadmap",
    createdField = false,
    sharedViewName = "Team table",
    failComment = false,
    uncertainComment = false;
  const comments = [{ id: 31, body: "The **release checklist** is ready.", user: { login: "reviewer" }, created_at: "2026-10-25T10:15:00Z" }];
  const release = () => ({
    id: 1,
    name: releaseName,
    tag_name: "v1.0",
    body: "Release notes",
    draft: true,
    updated_at: "stable",
    html_url: "https://github.com/team/repo/releases/tag/v1.0",
    assets: [
      {
        id: 2,
        name: "Desktop.zip",
        size: 1024,
        download_count: 12,
        browser_download_url:
          "https://github.com/team/repo/releases/download/v1.0/Desktop.zip",
      },
    ],
  });
  const sharedView = () => ({
    id: "VIEW",
    name: sharedViewName,
    number: 2,
    updatedAt: "stable",
    layout: "TABLE_LAYOUT",
    filter: "is:open",
    project: { id: "PROJECT" },
    configuration: {
      visibleFields: {
        nodes: [{ id: "STATUS" }],
        pageInfo: { hasNextPage: false },
      },
    },
    groupByFields: {
      nodes: [{ id: "STATUS" }],
      pageInfo: { hasNextPage: false },
    },
    sortByFields: { nodes: [], pageInfo: { hasNextPage: false } },
  });
  try {
    accounts.accounts = [
      {
        id: "hub-fixture",
        provider: "github",
        server: "https://github.com",
        username: "me",
        name: null,
        avatarURL: null,
      },
    ];
    accounts.token = async () => "fixture-only";
    ipc.openUrl = async () => {};
    ipc.http = async (method, url, _headers, body) => {
      const payload = body ? (JSON.parse(body) as Record<string, unknown>) : {};
      let result: unknown = {};
      let status = 200;
      const u = new URL(url);
      if (u.pathname === "/graphql") {
        const query = String(payload.query ?? "");
        if (query.includes("mutation")) {
          writes.push({ method, url, body: payload });
          const input = (
            payload.variables as { input?: Record<string, unknown> }
          )?.input;
          if (query.includes("updateProjectV2(input") && input?.title)
            projectName = String(input.title);
          if (query.includes("createProjectV2Field")) createdField = true;
          if (query.includes("updateProjectV2View") && input?.name)
            sharedViewName = String(input.name);
          result = {
            data: {
              updateProjectV2ItemFieldValue: { projectV2Item: { id: "ITEM" } },
              addProjectV2ItemById: { item: { id: "NEW" } },
              addProjectV2DraftIssue: { projectItem: { id: "DRAFT" } },
              createProjectV2View: { projectV2View: { id: "NEWVIEW" } },
            },
          };
        } else if (query.includes("views(first"))
          result = {
            data: {
              node: {
                id: "PROJECT",
                views: {
                  nodes: [sharedView()],
                  pageInfo: { hasNextPage: false },
                },
              },
            },
          };
        else if ((payload.variables as { id?: string })?.id === "VIEW")
          result = { data: { node: sharedView() } };
        else if (query.includes("node(id:"))
          result = {
            data: {
              node: {
                id: "PROJECT",
                title: projectName,
                readme: "",
                public: false,
                closed: false,
                updatedAt: "stable",
                shortDescription: "Plan releases",
                url: "https://github.com/orgs/team/projects/1",
                fields: {
                  nodes: [
                    ...(createdField
                      ? [{ id: "POINTS", name: "Estimate", dataType: "NUMBER" }]
                      : []),
                    {
                      id: "STATUS",
                      name: "Status",
                      options: [
                        { id: "TODO", name: "Todo" },
                        { id: "DONE", name: "Done" },
                      ],
                    },
                  ],
                  pageInfo: { hasNextPage: false },
                },
                items: {
                  nodes: projectEmpty
                    ? []
                    : [
                        {
                          id: "ITEM",
                          content: {
                            __typename: "Issue",
                            number: 2,
                            repository: { nameWithOwner: "team/repo" },
                            assignees: { nodes: [{ login: "me" }] },
                            labels: { nodes: [{ name: "release" }] },
                            id: "ISSUE",
                            title: "Ship the release",
                            body: "Review **release checklist**",
                            author: { login: "planner" }, createdAt: "2026-10-24T09:00:00Z",
                            url: "https://github.com/team/repo/issues/2",
                          },
                          fieldValues: {
                            nodes: [
                              { optionId: "TODO", field: { id: "STATUS" } },
                            ],
                            pageInfo: { hasNextPage: false },
                          },
                        },
                      ],
                  pageInfo: { hasNextPage: false },
                },
              },
            },
          };
        else
          result = {
            data: {
              repository: {
                owner: {
                  projectsV2: {
                    nodes: [
                      {
                        id: "PROJECT",
                        number: 1,
                        title: projectName,
                        shortDescription: "Plan releases",
                        url: "https://github.com/orgs/team/projects/1",
                      },
                    ],
                    pageInfo: { hasNextPage: false },
                  },
                },
              },
            },
          };
      } else if (method !== "GET") {
        writes.push({ method, url, body: payload });
        if (method === "PATCH" && url.includes("/releases/1"))
          releaseName = String(payload.name);
        if (u.pathname.endsWith("/issues/2/comments")) {
          if (uncertainComment) throw new Error("Synthetic lost comment response");
          if (failComment) { status = 422; result = { message: "Synthetic comment rejection" }; }
          else comments.push({ id: 32, body: String(payload.body), user: { login: "me" }, created_at: "2026-10-27T10:15:00Z" });
        }
      } else if (u.pathname.endsWith("/releases")) result = [release()];
      else if (u.pathname.endsWith("/releases/1")) result = release();
      else if (u.pathname === "/user/orgs")
        result = [{ id: 5, login: "team", description: "Studio" }];
      else if (u.pathname === "/orgs/team")
        result = {
          name: "Team",
          description: "Shared workspace",
          html_url: "https://github.com/team",
        };
      else if (u.pathname.endsWith("/orgs/team/repos"))
        result = [
          {
            id: 6,
            full_name: "team/client",
            description: "Desktop client",
            clone_url: "https://github.com/team/client.git",
            html_url: "https://github.com/team/client",
          },
        ];
      else if (u.pathname.endsWith("/orgs/team/members"))
        result = [{ id: 7, login: "reviewer" }];
      else if (u.pathname.endsWith("/issues/2/comments")) result = comments;
      else if (u.pathname.endsWith("/issues/2"))
        result = { node_id: "ISSUE", title: "Ship the release", body: "Review **release checklist**", state: "open" };
      else
        throw new Error(`Unexpected fixture request: ${method} ${u.pathname}`);
      return { status, body: status === 204 ? "" : JSON.stringify(result) };
    };
    await mount(<HostingHubPanel store={source} section="releases" />);
    ensure(
      await until(() => !!host.querySelector("button.hub-item")),
      "Release list did not render",
    );
    ensure(
      !host.querySelector(`select[aria-label="${t("Workspace account")}"]`),
      "Releases still offer their own account picker",
    );
    host.querySelector<HTMLButtonElement>("button.hub-item")!.click();
    ensure(
      await until(() => !!button("Download in browser")),
      "Release assets did not render",
    );
    button("Edit")!.click();
    await pause(30);
    const nameInput = [...host.querySelectorAll("label")]
      .find((l) => l.textContent?.trim() === t("Name"))!
      .querySelector("input")!;
    enter(nameInput, "Desktop 1.1");
    await pause(25);
    button("Review and save")!.click();
    await pause(25);
    ensure(writes.length === 0, "Release saved before confirmation");
    button("Confirm")!.click();
    ensure(
      await until(() => writes.some((w) => w.method === "PATCH")),
      "Release edit was not saved",
    );
    ensure(
      await until(() => host.textContent?.includes("Desktop 1.1") === true),
      "Release list did not refresh after save",
    );
    details.push("release assets + edit confirmation");
    const baseHTTP = ipc.http;
    ipc.http = async (method, url, headers, body) => {
      if (
        url.endsWith("/graphql") &&
        body &&
        String(JSON.parse(body).query).includes("user(login:$owner)")
      )
        return {
          status: 200,
          body: JSON.stringify({
            data: {
              user: {
                projectsV2: {
                  nodes: [
                    {
                      id: "PROJECT",
                      number: 2,
                      title: "Personal roadmap",
                      shortDescription: "My project",
                      url: "https://github.com/users/me/projects/2",
                    },
                  ],
                  pageInfo: { hasNextPage: false },
                },
              },
            },
          }),
        };
      return baseHTTP(method, url, headers, body);
    };
    await mount(<HostingHubPanel store={source} section="projects" />);
    ensure(
      await until(() => !!host.querySelector("button.hub-item")),
      "Owner projects missing",
    );
    const scope = host.querySelector<HTMLSelectElement>(
      `select[aria-label="${t("Project scope")}"]`,
    )!;
    ensure(!!scope, "Project scope picker missing");
    const beforeScope = writes.length;
    enter(scope, "personal");
    ensure(
      await until(
        () => host.textContent?.includes("Personal roadmap") === true,
      ),
      "Personal project scope did not load",
    );
    ensure(writes.length === beforeScope, "Scope selection mutated GitHub");
    enter(scope, "repository");
    ensure(
      await until(
        () =>
          host
            .querySelector("button.hub-item")
            ?.textContent?.includes("Plan releases") === true,
      ),
      "Repository project scope did not restore",
    );
    details.push("repository/personal project scopes");
    let startedTask = "";
    await mount(
      <HostingHubPanel
        store={source}
        section="projects"
        projectActions={{
          onStartTask: (row) => {
            startedTask = row.title;
          },
        }}
      />,
    );
    ensure(
      await until(() => !!host.querySelector(".project-overview")),
      "First project did not open its schedule overview automatically",
    );
    button("Board")!.click();
    await pause(25);
    ensure(
      host.querySelectorAll(".project-column").length === 2,
      "Status board did not show its columns",
    );
    ensure(
      host.querySelectorAll(".project-card").length === 1,
      "Project card was lost or duplicated",
    );
    const beforeView = writes.length;
    button("List")!.click();
    await pause(25);
    ensure(
      !!host.querySelector(".project-list") &&
        !host.querySelector(".project-board"),
      "List view did not replace board",
    );
    button("Timeline")!.click();
    await pause(25);
    ensure(!!host.querySelector(".project-roadmap"), "Timeline did not render");
    button("Board")!.click();
    await pause(25);
    ensure(
      !!host.querySelector(".project-board") && writes.length === beforeView,
      "Changing view wrote to GitHub",
    );
    const search = host.querySelector<HTMLInputElement>(
      `input[aria-label="${t("Search project items")}"]`,
    )!;
    enter(search, "does-not-match");
    await pause(25);
    ensure(
      host.querySelectorAll(".project-card").length === 0 &&
        host.querySelectorAll(".project-column").length === 2,
      "Filtering removed real status columns",
    );
    enter(search, "");
    await pause(25);
    host.querySelector<HTMLButtonElement>(".project-card")!.click();
    await pause(25);
    ensure(
      !!host.querySelector(".project-inspector"),
      "Task inspector did not open",
    );
    button("Start work on this task")!.click();
    await pause(25);
    ensure(
      startedTask === "Ship the release" && writes.length === beforeView,
      "Starting local work mutated GitHub",
    );
    ensure(await until(() => host.querySelectorAll(".project-comment").length === 1), "Fetched issue comments did not render");
    ensure(host.querySelector(".project-comment strong")?.textContent === "@reviewer" && !!host.querySelector(".project-comment .md strong"), "Comment author or Markdown was lost");
    ensure(host.querySelector(".project-comment time")?.getAttribute("datetime") === "2026-10-25T10:15:00.000Z", "Comment timestamp lost its seconds-to-date conversion");
    const commentInput = host.querySelector<HTMLTextAreaElement>(`textarea[aria-label="${t("Write a comment…")}"]`)!;
    enter(commentInput, "Ready for the next review.");
    await pause(25);
    failComment = true;
    button("Comment")!.click();
    ensure(await until(() => !!host.querySelector(".project-comment-editor [role=alert]")), "Rejected comment lacked an inline error");
    ensure(commentInput.value === "Ready for the next review.", "Rejected comment lost input");
    failComment = false;
    const commentWrites = writes.filter((write) => write.url.endsWith("/issues/2/comments")).length;
    button("Comment")!.click(); button("Comment")!.click();
    ensure(await until(() => host.querySelectorAll(".project-comment").length === 2 && commentInput.value === ""), "Posted comment did not refresh conversation");
    ensure(host.querySelector(".project-comment-notice")?.textContent === t("Comment posted"), "Confirmed comment lacked its posted notice");
    ensure(writes.filter((write) => write.url.endsWith("/issues/2/comments")).length === commentWrites + 1 && !host.querySelector(".hub-confirm"), "Comment posted twice or opened a second confirmation");
    enter(commentInput, "Check the uncertain reply.");
    await pause(25);
    uncertainComment = true;
    button("Comment")!.click();
    ensure(await until(() => host.textContent?.includes(t("The comment may have been posted. Refresh the conversation before trying again.")) === true && button("Comment")?.disabled === true), "Unknown comment result did not lock repeat submission");
    const uncertainWrites = writes.length;
    await pause(25);
    ensure(commentInput.value === "Check the uncertain reply." && writes.length === uncertainWrites, "Unknown comment was retried or lost input");
    uncertainComment = false;
    button("Retry")!.click();
    ensure(await until(() => button("Comment")?.disabled === false), "Project refresh did not reconcile the unknown comment lock");
    enter(commentInput, "");
    await pause(25);
    details.push("real issue comments + Markdown/author/time + retained rejected comment + guarded one-submit reply + unknown-result lock");
    const select = [...host.querySelectorAll(".project-inspector select")].find(
      (e) => (e as HTMLSelectElement).value === "TODO",
    ) as HTMLSelectElement;
    enter(select, "DONE");
    await pause(25);
    ensure(!host.querySelector(".hub-confirm"), "A field edit opened an extra review");
    ensure(
      await until(() =>
        writes.some((w) =>
          String(w.body.query).includes("updateProjectV2ItemFieldValue"),
        ),
      ),
      "Project status mutation missing",
    );
    ensure(
      await until(
        () => !!host.querySelector(".project-card") && !button("Confirm"),
      ),
      "Project did not refresh after a field edit",
    );
    host.querySelector<HTMLDetailsElement>(".project-task-more")!.open = true;
    host.querySelector<HTMLDetailsElement>(".project-order-menu")!.open = true;
    const position = host.querySelector<HTMLSelectElement>(
      `select[aria-label="${t("Move project item after")}"]`,
    )!;
    enter(position, "__top");
    await pause(25);
    const beforeMove = writes.length;
    button("Move")!.click();
    await pause(25);
    ensure(!host.querySelector(".hub-confirm"), "An item move opened an extra review");
    ensure(writes.length === beforeMove + 1, "Item move did not submit once");
    ensure(
      await until(
        () =>
          writes.some((write) =>
            String(write.body.query).includes("updateProjectV2ItemPosition"),
          ) &&
          !!host.querySelector(".project-list") &&
          !button("Confirm"),
      ),
      "Moving a task did not reveal native project order",
    );
    button("Board")!.click();
    await pause(25);
    host
      .querySelector<HTMLButtonElement>(".project-hero-actions .btn.primary")!
      .click();
    await pause(25);
    button("Paste a link")!.click();
    await pause(25);
    const issue = host.querySelector<HTMLInputElement>(
      `input[aria-label="${t("Issue URL")}"]`,
    )!;
    enter(issue, "https://github.com/team/repo/issues/2");
    await pause(25);
    const addButtons = [
      ...host.querySelectorAll<HTMLButtonElement>(".project-composer button"),
    ].filter((e) => e.textContent?.trim() === t("Add item"));
    addButtons[0]!.click();
    await pause(25);
    ensure(!host.querySelector(".hub-confirm"), "Adding an issue opened an extra review");
    ensure(
      await until(() =>
        writes.some((w) =>
          String(w.body.query).includes("addProjectV2ItemById"),
        ),
      ),
      "Issue was not added to project",
    );
    ensure(
      await until(
        () => !!host.querySelector(".project-card") && !button("Confirm"),
      ),
      "Project did not refresh after adding an issue",
    );
    host
      .querySelector<HTMLButtonElement>(".project-hero-actions .btn.primary")!
      .click();
    await pause(25);
    const draft = host.querySelector<HTMLInputElement>(
      `input[aria-label="${t("Draft title")}"]`,
    )!;
    enter(draft, "Plan the release");
    await pause(25);
    const beforeDraft = writes.length;
    host.querySelector<HTMLButtonElement>('.project-composer button[data-tip="' + t("Close") + '"]')!.click();
    await pause(25);
    ensure(writes.length === beforeDraft, "Closing the draft editor wrote a draft");
    host.querySelector<HTMLButtonElement>(".project-hero-actions .btn.primary")!.click();
    await pause(25);
    enter(host.querySelector<HTMLInputElement>(`input[aria-label="${t("Draft title")}"]`)!, "Plan the release");
    await pause(25);
    button("Create draft")!.click();
    await pause(25);
    ensure(!host.querySelector(".hub-confirm"), "Draft creation opened an extra review");
    ensure(
      await until(() =>
        writes.some((w) =>
          String(w.body.query).includes("addProjectV2DraftIssue"),
        ),
      ),
      "Draft mutation missing",
    );
    ensure(
      await until(
        () => !!host.querySelector('.project-saved-views option[value="VIEW"]'),
      ),
      "Shared views did not load",
    );
    const sharedPicker = host.querySelector<HTMLSelectElement>(
      `select[aria-label="${t("Shared view")}"]`,
    )!;
    const beforeShared = writes.length;
    enter(sharedPicker, "VIEW");
    await pause(25);
    ensure(
      !!host.querySelector(".project-list") &&
        host.textContent?.includes(
          t(
            "Saved filters run in GitHub. Native filters apply to the items loaded here.",
          ),
        ) === true,
      "Shared view configuration or honest filter notice missing",
    );
    ensure(
      writes.length === beforeShared,
      "Selecting a shared view wrote to GitHub",
    );
    enter(sharedPicker, "");
    button("Board")!.click();
    await pause(25);
    button("Select items")!.click();
    await pause(25);
    host.querySelector<HTMLButtonElement>(".project-card")!.click();
    await pause(25);
    const beforeBulk = writes.length;
    const bulkValue = host.querySelector<HTMLSelectElement>(
      `select[aria-label="${t("Bulk field value")}"]`,
    )!;
    enter(bulkValue, "DONE");
    await pause(25);
    button("Apply field")!.click();
    await pause(25);
    ensure(
      writes.length === beforeBulk,
      "Bulk action wrote before confirmation",
    );
    button("Confirm")!.click();
    ensure(
      await until(
        () =>
          writes.length > beforeBulk &&
          !host.querySelector(".project-bulk-actions"),
      ),
      "Confirmed bulk edit did not finish",
    );
    button("Project settings")!.click();
    await pause(25);
    const settings = host.querySelector(".project-settings")!;
    const projectNameInput = [...settings.querySelectorAll("label")]
      .find((label) => label.textContent?.trim() === t("Project name"))!
      .querySelector("input")!;
    enter(projectNameInput, "Release workspace");
    await pause(25);
    const beforeSettings = writes.length;
    [...settings.querySelectorAll<HTMLButtonElement>("button")]
      .find((button) => button.textContent?.trim() === t("Save changes"))!
      .click();
    await pause(25);
    ensure(!host.querySelector(".hub-confirm"), "Settings opened an extra review");
    ensure(writes.length === beforeSettings + 1, "Settings did not submit once");
    ensure(
      await until(
        () =>
          host.querySelector(".project-hero h1")?.textContent ===
          "Release workspace",
      ),
      "Project settings did not refresh",
    );
    const settingsTabs = [
      ...host.querySelectorAll<HTMLButtonElement>(
        ".project-settings .project-composer-tabs button",
      ),
    ];
    settingsTabs
      .find((button) => button.textContent?.trim() === t("Project fields"))!
      .click();
    await pause(25);
    button("New field")!.click();
    await pause(25);
    const fieldName = [...host.querySelectorAll(".project-settings label")]
      .find((label) => label.textContent?.trim() === t("Field name"))!
      .querySelector("input")!;
    enter(fieldName, "Estimate");
    await pause(25);
    const fieldType = [...host.querySelectorAll(".project-settings label")]
      .find((label) => label.textContent?.trim().startsWith(t("Field type")))!
      .querySelector("select")!;
    enter(fieldType, "number");
    await pause(25);
    [...host.querySelectorAll<HTMLButtonElement>(".project-settings button")]
      .find((button) => button.textContent?.trim() === t("Save field"))!
      .click();
    await pause(25);
    ensure(!host.querySelector(".hub-confirm"), "Field creation opened an extra review");
    ensure(
      await until(
        () =>
          host
            .querySelector(".project-field-catalog")
            ?.textContent?.includes("Estimate") === true,
      ),
      "Custom field creation did not refresh",
    );
    host
      .querySelector<HTMLButtonElement>(
        `button[aria-label="${t("Close project settings")}"]`,
      )!
      .click();
    await pause(25);
    button("New project")!.click();
    await pause(25);
    const beforeProject = writes.length;
    const newProject = host.querySelector<HTMLInputElement>(
      `input[aria-label="${t("Project name")}"]`,
    )!;
    enter(newProject, "New release plan");
    await pause(25);
    button("Review and create")!.click();
    await pause(25);
    ensure(
      writes.length === beforeProject,
      "Project created before confirmation",
    );
    button("Cancel")!.click();
    await pause(25);
    ensure(writes.length === beforeProject, "Cancel created a project");
    details.push(
      "shared view layout + filter boundary + reviewed bulk edits + direct settings/custom-field saves + project creation cancellation",
    );
    projectEmpty = true;
    await mount(<HostingHubPanel store={source} section="projects" />);
    ensure(await until(() => !!host.querySelector(".project-overview")), "Empty project overview missing");
    button("Board")!.click();
    ensure(
      await until(() => !!host.querySelector(".project-first-task")),
      "Empty project guidance missing",
    );
    ensure(
      host.querySelectorAll(".project-column").length === 2,
      "Empty project hid its real columns",
    );
    projectEmpty = false;
    details.push(
      "project auto-selection + real empty columns + Board/List/Timeline + filters + inspector + local task handoff + single-submit fields/issues/drafts",
    );
    const githubAccounts = accounts.accounts,
      githubHTTP = ipc.http;
    accounts.accounts = [
      {
        id: "gitlab-fixture",
        provider: "gitlab",
        server: "https://gitlab.test",
        username: "me",
        name: null,
        avatarURL: null,
      },
    ];
    const gitlabSource = {
      ...source,
      target: {
        provider: "gitlab",
        host: "gitlab.test",
        path: "team/repo",
        remote: "origin",
      } as RepoTarget,
    };
    ipc.http = async (method, url, _headers, body) => {
      const path = new URL(url).pathname;
      let result: unknown;
      if (method === "PUT") {
        const payload = JSON.parse(body!);
        writes.push({ method, url, body: payload });
        result = {};
      } else if (path.endsWith("/boards"))
        result = [{ id: 1, name: "Release board" }];
      else if (path.endsWith("/boards/1"))
        result = { id: 1, name: "Release board" };
      else if (path.endsWith("/boards/1/lists"))
        result = [
          { label: { id: 1, name: "Ready" } },
          { label: { id: 2, name: "Doing" } },
        ];
      else if (path.endsWith("/issues/7"))
        result = {
          iid: 7,
          id: 77,
          labels: ["Ready", "security"],
          state: "opened",
        };
      else if (path.endsWith("/issues"))
        result = [
          {
            iid: 7,
            id: 77,
            title: "Fix keyboard navigation",
            labels: ["Ready", "security"],
            state: "opened",
            web_url: "https://gitlab.test/team/repo/-/issues/7",
          },
        ];
      else throw new Error(`Unexpected GitLab fixture: ${method} ${path}`);
      return { status: 200, body: JSON.stringify(result) };
    };
    await mount(<HostingHubPanel store={gitlabSource} section="projects" />);
    ensure(
      await until(() => !!host.querySelector(".project-card")),
      "GitLab board did not open",
    );
    host.querySelector<HTMLButtonElement>(".project-card")!.click();
    await pause(25);
    const gitlabColumn = host.querySelector<HTMLSelectElement>(
      ".project-inspector select",
    )!;
    enter(gitlabColumn, "2");
    await pause(25);
    ensure(!host.querySelector(".hub-confirm"), "GitLab field edit opened an extra review");
    ensure(
      await until(() =>
        writes.some(
          (write) =>
            write.method === "PUT" && write.body.add_labels === "Doing",
        ),
      ),
      "GitLab board field used the wrong provider mutation",
    );
    const moved = writes.find(
      (write) => write.method === "PUT" && write.body.add_labels === "Doing",
    )!;
    ensure(
      moved.body.remove_labels === "Ready",
      "GitLab move changed an unrelated label",
    );
    accounts.accounts = githubAccounts;
    ipc.http = githubHTTP;
    details.push(
      "GitLab board provider actions + unrelated label preservation",
    );
    let cloneURL = "";
    await mount(
      <HostingHubPanel
        store={source}
        section="organizations"
        onClone={(url) => {
          cloneURL = url;
        }}
      />,
    );
    ensure(
      await until(() => !!host.querySelector("button.hub-item")),
      "Organization list did not render",
    );
    ensure(
      host.querySelector(".hub-organization-row > .avatar")?.textContent === "T",
      "Organization list icon fallback missing",
    );
    host.querySelector<HTMLButtonElement>("button.hub-item")!.click();
    ensure(
      await until(() => !!button("Clone")),
      "Organization repository did not render",
    );
    ensure(
      host.querySelector(".hub-organization-heading > .avatar")?.textContent === "T",
      "Organization detail icon fallback missing",
    );
    button("Clone")!.click();
    ensure(
      cloneURL === "https://github.com/team/client.git",
      "Clone destination missing",
    );
    button("Members")!.click();
    ensure(
      await until(() => host.textContent?.includes("reviewer") === true),
      "Organization members did not render",
    );
    details.push("organization icons + repositories + members + clone");
    await mount(<HostingHubPanel store={source} section="releases" />);
    ensure(await until(() => !!host.querySelector("button.hub-item")), "Release list did not render again");
    host.querySelector<HTMLButtonElement>("button.hub-item")!.click();
    ensure(await until(() => !!button("Delete")), "Release delete control missing");
    button("Delete")!.click();
    await pause(25);
    const before = writes.length;
    button("Cancel")!.click();
    await pause(25);
    ensure(writes.length === before, "Cancel deleted the release");
    details.push("release delete cancellation");
    return [true, details.join("; ")];
  } catch (e) {
    return [
      false,
      [...details, e instanceof Error ? e.message : String(e)].join("; "),
    ];
  } finally {
    root.unmount();
    host.remove();
    ipc.http = original.http;
    ipc.openUrl = original.openUrl;
    accounts.token = original.token;
    accounts.accounts = original.accounts;
  }
}
