import {
  accounts,
  ProjectPortfolioState,
  localScheduleToday,
  scheduleAddDays,
  type HubDetail,
  type HubProjectRow,
} from "@/entities/hosting";
import { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { useObserve } from "@/shared/lib";
import { WorkspacePlanningDashboard } from "@/widgets/workspace-panels";
import { HostingHubPanel } from "@/widgets/hosting-hub";

/** Isolated demo data for the real Home and Projects components. */
export function planningFixture() {
  const today = localScheduleToday(),
    date = (days: number) => scheduleAddDays(today, days)!,
    fields: HubDetail["fields"] = [
      { id: "DUE", name: "Due date", kind: "date", options: [] },
      { id: "START", name: "Start date", kind: "date", options: [] },
      {
        id: "STATUS",
        name: "Status",
        kind: "singleSelect",
        options: [
          { id: "READY", name: "Ready" },
          { id: "DONE", name: "Done" },
        ],
      },
    ],
    row = (
      id: string,
      title: string,
      offset?: number,
      person = "planner",
      contentID = id,
    ): HubProjectRow => ({
      id,
      title,
      contentID,
      kind: "issue",
      body: "A clear next step for the release.",
      url: `https://github.com/team/repo/issues/${contentID.replace(/\D/g, "") || 1}`,
      repository: "team/repo",
      assignees: [person],
      statuses: { STATUS: "READY" },
      values: offset === undefined ? {} : { DUE: date(offset) },
    }),
    sharedA = row("A1", "Shared delivery task", 3, "planner", "ISSUE1"),
    sharedB = row("B1", "Shared delivery task", 1, "planner", "ISSUE1"),
    draft = {
      ...row("DRAFT", "Explore the next idea"),
      kind: "draft" as const,
      url: "",
      assignees: [],
    },
    details: HubDetail[] = [
      {
        item: {
          id: "RELEASE",
          title: "Release engineering",
          subtitle: "#1",
          body: "Ship focused changes with confidence.",
          url: "https://github.com/orgs/team/projects/1",
          data: {},
        },
        fields,
        rows: [
          sharedA,
          row("A2", "Resolve release blockers", -2, "reviewer", "ISSUE2"),
          row("A3", "Review the release checklist", 0, "planner", "ISSUE3"),
          draft,
          {
            ...row(
              "A4",
              "Ship the account improvements",
              -1,
              "planner",
              "ISSUE4",
            ),
            state: "CLOSED",
            statuses: { STATUS: "DONE" },
          },
        ],
        files: [],
        repositories: [],
        members: [],
        assets: [],
        more: false,
      },
      {
        item: {
          id: "QUALITY",
          title: "Product quality",
          subtitle: "#2",
          body: "Keep the product calm and reliable.",
          url: "https://github.com/orgs/team/projects/2",
          data: {},
        },
        fields,
        rows: [
          sharedB,
          row("B2", "Polish the onboarding journey", 5, "designer", "ISSUE5"),
        ],
        files: [],
        repositories: [],
        members: [],
        assets: [],
        more: false,
      },
    ];
  const data = new ProjectPortfolioState({
    page: async () => ({
      items: details.map((detail) => detail.item),
      more: false,
    }),
    detail: async (_c, item) =>
      details.find((detail) => detail.item.id === item.id)!,
  });
  data.projects = details.map((detail) => detail.item);
  data.details = details;
  data.selectedIDs = data.projects.map((item) => item.id);
  const store = new RepoStore();
  store.path = "C:/planning-fixture";
  store.target = {
    provider: "github",
    host: "github.com",
    path: "team/repo",
    remote: "origin",
  };
  store.navigate = (destination) => {
    store.destination = destination;
    store.changed();
    return true;
  };
  const original = {
    http: ipc.http,
    token: accounts.token,
    accounts: accounts.accounts,
  };
  let writes = 0,
    itemPages = 0;
  accounts.accounts = [
    {
      id: "planning-fixture",
      provider: "github",
      server: "https://github.com",
      username: "planner",
      name: null,
      avatarURL: null,
    },
  ];
  accounts.token = async () => "fixture-only";
  const selectionContext = JSON.stringify([
    "planning-fixture",
    "personal",
    store.path,
    store.target,
  ]);
  data.reset(JSON.stringify(["remote", selectionContext, accounts.revision]));
  data.projects = details.map((detail) => detail.item);
  data.details = details;
  data.selectedIDs = data.projects.map((item) => item.id);
  const graphNode = (detail: HubDetail, later = false) => ({
    ...detail.item,
    title: detail.item.title,
    fields: {
      nodes: detail.fields.map((field) => ({
        ...field,
        dataType: field.kind === "date" ? "DATE" : "SINGLE_SELECT",
      })),
      pageInfo: { hasNextPage: false },
    },
    items: {
      nodes: (detail.item.id === "QUALITY"
        ? detail.rows.filter((row) =>
            later ? row.id === "B1" : row.id !== "B1",
          )
        : detail.rows
      ).map((row) => ({
        id: row.id,
        isArchived: false,
        content: {
          __typename: row.kind === "draft" ? "DraftIssue" : "Issue",
          id: row.contentID,
          title: row.title,
          body: row.body,
          url: row.url,
          state: row.state ?? "OPEN",
          number: Number(row.contentID.replace(/\D/g, "")) || 1,
          repository: { nameWithOwner: row.repository },
          assignees: { nodes: row.assignees?.map((login) => ({ login })) },
        },
        fieldValues: {
          nodes: [
            ...Object.entries(row.values ?? {}).map(([id, date]) => ({
              date,
              field: { id },
            })),
            { optionId: row.statuses.STATUS, field: { id: "STATUS" } },
          ],
          pageInfo: { hasNextPage: false },
        },
      })),
      pageInfo: {
        hasNextPage: detail.item.id === "QUALITY" && !later,
        endCursor:
          detail.item.id === "QUALITY" && !later ? "QUALITY_PAGE_2" : null,
      },
    },
  });
  ipc.http = async (_method, _url, _headers, body) => {
    const payload = JSON.parse(body ?? "{}"),
      query = String(payload.query ?? ""),
      id = payload.variables?.id;
    if (query.includes("mutation")) {
      writes++;
      throw new Error("Unexpected fixture mutation");
    }
    const nodes = details.map((detail) => ({
      ...detail.item,
      number: detail.item.id === "RELEASE" ? 1 : 2,
      shortDescription: detail.item.body,
    }));
    if (payload.variables?.cursor === "QUALITY_PAGE_2") itemPages++;
    const value = query.includes("views(first")
      ? { node: { id, views: { nodes: [], pageInfo: { hasNextPage: false } } } }
      : id
        ? {
            node: graphNode(
              details.find((detail) => detail.item.id === id)!,
              !!payload.variables?.cursor,
            ),
          }
        : {
            user: { projectsV2: { nodes, pageInfo: { hasNextPage: false } } },
            repository: {
              owner: {
                projectsV2: { nodes, pageInfo: { hasNextPage: false } },
              },
            },
          };
    return { status: 200, body: JSON.stringify({ data: value }) };
  };
  return {
    data,
    store,
    details,
    selectionContext,
    get writes() {
      return writes;
    },
    get itemPages() {
      return itemPages;
    },
    restore: () => {
      ipc.http = original.http;
      accounts.token = original.token;
      accounts.accounts = original.accounts;
    },
  };
}
export function PlanningFixtureShell({
  fixture,
}: {
  fixture: ReturnType<typeof planningFixture>;
}) {
  useObserve(fixture.store);
  return fixture.store.destination === "projects" ? (
    <HostingHubPanel store={fixture.store} section="projects" />
  ) : (
    <WorkspacePlanningDashboard store={fixture.store} fixture={fixture.data} />
  );
}
