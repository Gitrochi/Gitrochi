/** Isolated visual fixture. Network, Git and browser actions are disabled. */
import { ipc } from "../src/shared/api";
import { createRoot } from "react-dom/client";
import "../src/app/styles/global.css";
import "../src/widgets/hosting-hub/ui/hosting-hub.css";
import { ProjectWorkspace } from "../src/widgets/hosting-hub/ui/ProjectWorkspace";
import { loadLanguage } from "../src/shared/i18n";
import type { HubDetail } from "../src/entities/hosting";
const params = new URLSearchParams(location.search);
await loadLanguage(params.get("lang") ?? "en");
document.documentElement.dataset.theme = params.get("theme") ?? "light";
const fields: HubDetail["fields"] = [
  {
    id: "status",
    name: "Status",
    kind: "singleSelect",
    options: [
      { id: "backlog", name: "Backlog" },
      { id: "ready", name: "Ready" },
      { id: "progress", name: "In progress" },
      { id: "done", name: "Done" },
    ],
  },
  {
    id: "priority",
    name: "Priority",
    kind: "singleSelect",
    options: [
      { id: "high", name: "High priority" },
      { id: "medium", name: "Medium" },
    ],
  },
  { id: "date", name: "Target date", kind: "date", options: [] },
  { id: "start", name: "Start date", kind: "date", options: [] },
  { id: "points", name: "Estimate", kind: "number", options: [] },
];
const detail: HubDetail = {
  item: {
    id: "PROJECT",
    title: "The next great release",
    subtitle: "#4",
    body: "A focused workspace for the team. Turn the roadmap into code, one meaningful change at a time.",
    url: "https://github.com/orgs/team/projects/4",
    data: {},
  },
  members: [],
  repositories: [],
  assets: [],
  fields,
  more: false,
  rows: [
    {
      id: "1",
      title: "Make command search feel instant",
      body: "Keep the keyboard flow fast, predictable, and accessible.",
      url: "https://github.com/team/desktop/issues/42",
      contentID: "I1",
      kind: "issue",
      number: 42,
      repository: "team/desktop",
      assignees: ["alex", "sam"],
      labels: ["experience"],
      statuses: { status: "progress", priority: "high" },
      values: { start: "2030-02-10", date: "2030-02-15", points: "5" },
    },
    {
      id: "2",
      title: "Bring every review into one place",
      body: "Review discussions and code changes without losing the task context.",
      url: "https://github.com/team/desktop/pull/56",
      contentID: "P1",
      kind: "pullRequest",
      number: 56,
      repository: "team/desktop",
      assignees: ["sam"],
      labels: ["review"],
      statuses: { status: "progress" },
      values: { start: "2030-02-12", date: "2030-02-18" },
    },
    {
      id: "3",
      title: "Design a calmer first launch",
      body: "Help a new teammate find their next step.",
      url: "",
      contentID: "D1",
      kind: "draft",
      labels: ["design"],
      statuses: { status: "ready" },
      values: {},
    },
    {
      id: "4",
      title: "Polish the empty states",
      body: "Every empty state should invite a useful next action.",
      url: "https://github.com/team/desktop/issues/38",
      contentID: "I2",
      kind: "issue",
      number: 38,
      repository: "team/desktop",
      assignees: ["alex"],
      labels: ["polish"],
      statuses: { status: "ready", priority: "medium" },
      values: {},
    },
    {
      id: "5",
      title: "Reduce cold-start work",
      body: "Measure startup and defer nonessential work.",
      url: "https://github.com/team/core/issues/12",
      contentID: "I3",
      kind: "issue",
      number: 12,
      repository: "team/core",
      assignees: ["taylor"],
      labels: ["performance"],
      statuses: { status: "backlog" },
      values: {},
    },
    {
      id: "6",
      title: "Ship the new account switcher",
      body: "",
      url: "https://github.com/team/desktop/pull/31",
      contentID: "P2",
      kind: "pullRequest",
      number: 31,
      repository: "team/desktop",
      assignees: ["alex"],
      state: "MERGED",
      statuses: { status: "done" },
      values: {},
    },
  ],
};
if (params.has("empty")) detail.rows = [];
const sharedViews = [
  { id: "BOARD", name: "Delivery board", number: 1, layout: "BOARD_LAYOUT" },
  { id: "TABLE", name: "Team table", number: 2, layout: "TABLE_LAYOUT" },
  {
    id: "ROADMAP",
    name: "Release roadmap",
    number: 3,
    layout: "ROADMAP_LAYOUT",
  },
].map((view) => ({
  ...view,
  filter: "",
  project: { id: "PROJECT" },
  configuration: {
    visibleFields: {
      nodes: [{ id: "status" }, { id: "priority" }, { id: "date" }],
      pageInfo: {},
    },
  },
  groupByFields: { nodes: [{ id: "status" }], pageInfo: {} },
  sortByFields: { nodes: [], pageInfo: {} },
}));
ipc.http = async () => ({
  status: 200,
  body: JSON.stringify({
    data: {
      node: { id: "PROJECT", views: { nodes: sharedViews, pageInfo: {} } },
    },
  }),
});
const readAccess = async () => ({
  target: {
    provider: "github" as const,
    host: "github.com",
    path: "team/desktop",
    remote: "origin",
  },
  token: "fixture-only",
  apiBase: "https://api.github.com",
  me: "alex",
});
createRoot(document.getElementById("root")!).render(
  <section
    className="hosting-hub hosting-hub-projects"
    style={{ height: "100vh" }}
  >
    <ProjectWorkspace
      detail={detail}
      locked={false}
      gitlab={false}
      open={() => {}}
      safe={() => true}
      ask={() => {}}
      local={{
        repository: "team/desktop",
        host: "github.com",
        onStartTask: () => {},
        onOpenRequest: () => {},
      }}
      me="alex"
      readAccess={readAccess}
    />
  </section>,
);
if (params.has("inspector"))
  setTimeout(
    () =>
      [...document.querySelectorAll<HTMLButtonElement>(".project-card")]
        .find((button) => button.textContent?.includes("Make command search"))
        ?.click(),
    200,
  );
if (params.get("view"))
  setTimeout(
    () =>
      document
        .querySelectorAll<HTMLButtonElement>(".project-view-switch .btn")
        [params.get("view") === "timeline" ? 2 : 1]?.click(),
    200,
  );
if (params.has("selftest")) {
  const { hostingHubSelfTest } = await import(
    "../src/app/lib/hosting-hub-selftest"
  );
  const result = await hostingHubSelfTest();
  const output = document.createElement("pre");
  output.id = "selftest-result";
  output.dataset.passed = String(result[0]);
  output.textContent = result[1];
  document.body.append(output);
}

if (params.has("settings"))
  setTimeout(() => {
    document
      .querySelector<HTMLButtonElement>(
        ".project-hero-actions button:last-child",
      )
      ?.click();
    if (params.get("settings") !== "project")
      setTimeout(
        () =>
          document
            .querySelectorAll<HTMLButtonElement>(
              ".project-settings .project-composer-tabs button",
            )
            [params.get("settings") === "fields" ? 1 : 2]?.click(),
        100,
      );
  }, 250);
if (params.has("bulk"))
  setTimeout(
    () =>
      [
        ...document.querySelectorAll<HTMLButtonElement>(
          ".project-toolbar button",
        ),
      ]
        .find(
          (button) =>
            button.textContent?.includes("Select") ||
            button.textContent?.includes("항목 선택"),
        )
        ?.click(),
    250,
  );
