/** Isolated visual fixture. All requests, tokens, invitations and browser actions stay in memory. */
import { createRoot } from "react-dom/client";
import { accounts, HostingHubStore } from "../src/entities/hosting";
import { ipc } from "../src/shared/api";
import { loadLanguage } from "../src/shared/i18n";
import { HostingHubPanel } from "../src/widgets/hosting-hub";
import "../src/app/styles/global.css";
const params = new URLSearchParams(location.search);
await loadLanguage(params.get("lang") ?? "en");
document.documentElement.dataset.theme = params.get("theme") ?? "light";
const gitlab = params.has("gitlab");
const provider = gitlab ? "gitlab" as const : "github" as const;
const host = gitlab ? "gitlab.example.com" : "github.com";
accounts.accounts = [{ id: "fixture-account", provider, server: `https://${host}`, username: "demo", name: null, avatarURL: null }];
accounts.token = async () => "fixture-token";
ipc.openUrl = async () => {};
ipc.http = async (method, url) => {
  const path = new URL(url).pathname;
  let value: unknown;
  if (method !== "GET") value = gitlab ? { status: "success" } : { id: 10 };
  else if (path === "/user/orgs" || path === "/api/v4/groups") value = [{ id: 5, login: "demo-team", name: "Demo studio", description: "One place for the people, projects and tools that move our work forward.", full_path: "demo-team", web_url: `https://${host}/demo-team` }, { id: 6, login: "community-labs", name: "Community labs", description: "Open source experiments", full_path: "community-labs", web_url: `https://${host}/community-labs` }];
  else if (path.includes("/user/memberships/")) value = { role: "admin", state: "active" };
  else if (path.endsWith("/user")) value = { id: 9, username: "demo" };
  else if (path.endsWith("/members/all/9")) value = { id: 9, username: "demo", access_level: 50 };
  else if (path.endsWith("/invitations")) value = [{ id: 10, email: "teammate@example.com", invite_email: "teammate@example.com", role: "direct_member", access_level: 30, created_at: "2026-10-28", expires_at: "2026-11-28" }];
  else if (path.endsWith("/teams") || path.endsWith("/subgroups")) value = [{ id: 20, name: "Desktop team", description: "Build an excellent desktop experience.", privacy: "closed", html_url: "https://github.com/orgs/demo-team/teams/desktop", web_url: `https://${host}/demo-team/desktop` }, { id: 21, name: "Platform team", description: "Keep shared infrastructure healthy.", privacy: "closed", html_url: "https://github.com/orgs/demo-team/teams/platform", web_url: `https://${host}/demo-team/platform` }];
  else if (path.endsWith("/repos") || path.endsWith("/projects")) value = [{ id: 30, full_name: "demo-team/desktop", path_with_namespace: "demo-team/desktop", description: "The desktop application", clone_url: `https://${host}/demo-team/desktop.git`, http_url_to_repo: `https://${host}/demo-team/desktop.git`, html_url: `https://${host}/demo-team/desktop`, web_url: `https://${host}/demo-team/desktop` }];
  else if (path.endsWith("/members") || path.endsWith("/members/all")) value = [{ id: 40, login: "demo", username: "demo", name: "Demo contributor", access_level: 50, html_url: `https://${host}/demo`, web_url: `https://${host}/demo` }];
  else if (path.endsWith("/demo-team") || path.endsWith("/5")) value = { id: 5, login: "demo-team", name: "Demo studio", description: "One place for the people, projects and tools that move our work forward.", html_url: `https://${host}/demo-team`, web_url: `https://${host}/demo-team`, public_repos: gitlab ? undefined : 24, total_private_repos: gitlab ? undefined : 8, location: "Remote", blog: "https://example.com", visibility: gitlab ? "private" : undefined };
  else throw new Error(`Unexpected fixture request: ${method} ${path}`);
  return { status: method === "DELETE" ? 204 : 200, body: method === "DELETE" ? "" : JSON.stringify(value) };
};
const source = { path: null, target: null, hostingAccount: accounts.accounts[0] };
const hub = new HostingHubStore(source);
const viewSource = { ...source, hostingHub: hub };
const root = createRoot(document.getElementById("root")!);
root.render(<div style={{ height: "100%", display: "flex", flexDirection: "column", background: "var(--surface)" }}><div style={{ padding: "22px 24px 0" }}><span style={{ color: "var(--text-2)", fontSize: 12 }}>Gitrochi · Account workspace</span><h1 style={{ margin: "8px 0 0", fontSize: 24 }}>{gitlab ? "Groups" : "Organizations"}</h1></div><HostingHubPanel store={viewSource} section="organizations" onClone={() => {}}/></div>);
setTimeout(() => { const first = hub.items[0]; if (first) void hub.select(first, false, params.get("tab") === "invitations" ? "invitations" : params.get("tab") === "teams" ? "teams" : "overview"); }, 100);
if (params.has("selftest")) {
  const { hostingHubSelfTest } = await import("../src/app/lib/hosting-hub-selftest");
  const result = await hostingHubSelfTest();
  const output = document.createElement("pre"); output.id = "organizations-selftest-result"; output.dataset.passed = String(result[0]); output.textContent = result[1]; document.body.append(output);
}
