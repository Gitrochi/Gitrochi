import { accounts, localProjects, LocalProjectStore } from "@/entities/hosting";
import { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { useObserve } from "@/shared/lib";
import { HostingHubPanel } from "@/widgets/hosting-hub";
import { WorkspacePlanningDashboard } from "@/widgets/workspace-panels";
/** The real UI and local model use a test-only atomic document; live transport is rejected. */
export function localPlannerFixture() {
  const selectionKey = "gitrochi.project-portfolio-selection.v1:local",
    originalSelection = localStorage.getItem(selectionKey);
  localStorage.removeItem(selectionKey);
  const original = {
    read: ipc.localProjectsRead,
    write: ipc.localProjectsWrite,
    http: ipc.http,
    token: accounts.token,
    accounts: accounts.accounts,
    projects: localProjects.projects,
    revision: localProjects.revision,
    loaded: localProjects.loaded,
    error: localProjects.error,
  };
  let document: string | null = null,
    writes = 0,
    http = 0,
    credentials = 0,
    remoteWrites = 0,
    release: () => void = () => {};
  let slow = false;
  const store = new RepoStore();
  store.destination = "projects";
  store.hostingHub.projectSource = "local";
  store.navigate = (destination) => {
    store.destination = destination;
    store.changed();
    return true;
  };
  ipc.localProjectsRead = async () => document;
  ipc.localProjectsWrite = async (expected, content) => {
    if (expected !== document) throw new Error("Stale test document");
    document = content;
    writes++;
  };
  accounts.accounts = [];
  accounts.token = async () => {
    credentials++;
    return "synthetic-only";
  };
  ipc.http = async (method, url, _headers, body) => {
    http++;
    const payload = JSON.parse(body ?? "{}"),
      query = String(payload.query ?? "");
    if (query.includes("mutation") || !["GET", "POST"].includes(method)) {
      remoteWrites++;
      throw new Error("No live writes in this fixture");
    }
    if (url.endsWith("/user")) {
      const login = store.hostingHub.account?.username ?? "planner";
      if (slow) {
        slow = false;
        await new Promise<void>((resolve) => {
          release = resolve;
        });
      }
      return {
        status: 200,
        body: JSON.stringify({
          login,
          plan: { name: login === "planner" ? "free" : "pro" },
        }),
      };
    }
    const login = String(
      payload.variables?.owner ??
        store.hostingHub.account?.username ??
        "planner",
    );
    return {
      status: 200,
      body: JSON.stringify({
        data: {
          repositoryOwner: { id: `owner-${login}`, login, __typename: "User" },
          user: { projectsV2: { nodes: [], pageInfo: { hasNextPage: false } } },
        },
      }),
    };
  };
  return {
    store,
    get document() {
      return document;
    },
    get writes() {
      return writes;
    },
    get http() {
      return http;
    },
    get credentials() {
      return credentials;
    },
    get remoteWrites() {
      return remoteWrites;
    },
    slowProbe() {
      slow = true;
    },
    releaseProbe() {
      release();
    },
    connect() {
      accounts.accounts = ["planner", "second"].map((username) => ({
        id: `fixture-${username}`,
        username,
        provider: "github" as const,
        server: "https://github.com",
        name: null,
        avatarURL: null,
      }));
    },
    async reopen() {
      const model = new LocalProjectStore({
        read: async () => document,
        write: async () => {
          throw new Error("Read-only restart check");
        },
      });
      await model.load();
      return model;
    },
    restore() {
      if (originalSelection === null) localStorage.removeItem(selectionKey);
      else localStorage.setItem(selectionKey, originalSelection);
      for (const item of localProjects.projects)
        localStorage.removeItem(
          `gitrochi.project-schedule.v1:local:${item.id}`,
        );
      ipc.localProjectsRead = original.read;
      ipc.localProjectsWrite = original.write;
      ipc.http = original.http;
      accounts.token = original.token;
      accounts.accounts = original.accounts;
      localProjects.projects = original.projects;
      localProjects.revision = original.revision;
      localProjects.loaded = original.loaded;
      localProjects.error = original.error;
      store.hostingHub.reset();
    },
  };
}
export function LocalPlannerFixtureShell({
  fixture,
}: {
  fixture: ReturnType<typeof localPlannerFixture>;
}) {
  useObserve(fixture.store);
  return fixture.store.destination === "home" ? (
    <WorkspacePlanningDashboard store={fixture.store} />
  ) : (
    <HostingHubPanel store={fixture.store} section="projects" />
  );
}
