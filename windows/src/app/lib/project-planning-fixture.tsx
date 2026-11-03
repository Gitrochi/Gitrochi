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
export function planningFixture({ organization = false, complete = false }: { organization?: boolean; complete?: boolean } = {}) {
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

        repositories: [],
        members: [],
        assets: [],
        more: false,
      },
    ];
  if (complete) {
    const archived = Array.from({length:100}, (_, index) => ({...row(`ARCHIVE${index}`, `Archived delivery ${index + 1}`, undefined, "reviewer", `ARCHIVE${index}`), archived:true}));
    const issues = Array.from({length:100}, (_, index) => ({...row(`ITEM${index}`, `Delivery task ${index + 1}`, index % 7, "planner", `COMPLETE${index}`), state:index % 3 === 0 ? "CLOSED" : "OPEN"}));
    details.splice(1);
    details[0].rows = [...archived, ...issues,
      {...draft, id:"LAST_DRAFT", title:"Final planning draft", contentID:"LAST_DRAFT"},
      {...row("LAST_PR", "Merged delivery change", 1, "reviewer", "LAST_PR"), kind:"pullRequest", state:"MERGED"},
      {...row("REDACTED", "Restricted item"), kind:"redacted", contentID:"", url:""},
    ];
  }
  const data = complete ? new ProjectPortfolioState() : new ProjectPortfolioState({
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
  if (organization) { store.path = null; store.target = null; store.hostingHub.projectScope = "organization:team"; }
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
  const selectionContext = JSON.stringify(["planning-fixture", organization ? "organization:team" : "personal"]);
  data.reset(JSON.stringify(["remote", selectionContext, accounts.revision]));
  data.projects = details.map((detail) => detail.item);
  data.details = details;
  data.selectedIDs = data.projects.map((item) => item.id);
  const graphNode = (detail: HubDetail, cursor?: string) => {
    const later = !!cursor, offset = complete ? Number(cursor?.replace("COMPLETE_", "") ?? 0) : 0;
    const pageRows = complete ? detail.rows.slice(offset, offset + 100) : detail.item.id === "QUALITY" ? detail.rows.filter(row => later ? row.id === "B1" : row.id !== "B1") : detail.rows;
    return ({
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
      nodes: pageRows.map((row) => ({
        id: row.id,
        isArchived: !!row.archived,
        content: row.kind === "redacted" ? null : {
          __typename: row.kind === "draft" ? "DraftIssue" : row.kind === "pullRequest" ? "PullRequest" : "Issue",
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
        hasNextPage: complete ? offset + 100 < detail.rows.length : detail.item.id === "QUALITY" && !later,
        endCursor: complete ? offset + 100 < detail.rows.length ? `COMPLETE_${offset + 100}` : null : detail.item.id === "QUALITY" && !later ? "QUALITY_PAGE_2" : null,
      },
    },
  });
  };
  ipc.http = async (_method, url, _headers, body) => {
    if (new URL(url).pathname === "/user/orgs") return { status: 200, body: JSON.stringify([{login:"team", name:"Demo team"}]) };
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
    if (payload.variables?.cursor) itemPages++;
    const value = query.includes("views(first")
      ? { node: { id, views: { nodes: [], pageInfo: { hasNextPage: false } } } }
      : id
        ? {
            node: graphNode(
              details.find((detail) => detail.item.id === id)!,
              payload.variables?.cursor ?? undefined,
            ),
          }
        : {
            user: { projectsV2: { nodes, pageInfo: { hasNextPage: false } } },
            organization: { projectsV2: { nodes, pageInfo: { hasNextPage: false } } },
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
    load: async () => {
      if (complete) {
        data.reset(JSON.stringify(["remote", selectionContext, accounts.revision]));
        await data.load({target:{provider:"github",host:"github.com",path:"team/workspace",remote:"origin"}, token:"fixture-only",apiBase:"https://api.github.com",me:"planner",projectOrganization:organization ? "team" : undefined}, JSON.stringify(["remote", selectionContext, accounts.revision]));
      }
    },
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
