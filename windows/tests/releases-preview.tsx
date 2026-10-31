import { createRoot } from "react-dom/client";
import { HostingHubPanel } from "../src/widgets/hosting-hub";
import { accounts, releasePortfolio } from "../src/entities/hosting";
import { workspace } from "../src/entities/workspace";
import { IssueDetail } from "../src/widgets/inspector";
import { useObserve } from "../src/shared/lib";
import { RepoStore } from "../src/entities/repo";
import { ReleaseOverview } from "../src/widgets/workspace-panels";
import { ipc } from "../src/shared/api";
import { loadLanguage } from "../src/shared/i18n";
import { issueWorkflowSelfTest } from "../src/app/lib/issue-workflow-selftest";
import { releaseOverviewSelfTest } from "../src/app/lib/release-overview-selftest";
import { hostingHubSelfTest } from "../src/app/lib/hosting-hub-selftest";
import "../src/app/styles/global.css";
const params = new URLSearchParams(location.search);
await loadLanguage(params.get("lang") ?? "en");
document.documentElement.dataset.theme = params.get("theme") ?? "light";
const root = document.getElementById("root")!;
if (params.get("mode") === "issues") {
  const store = new RepoStore(); store.path = "/fixture/desktop";
  store.target = { provider: "github", host: "github.com", path: "sample-studio/desktop", remote: "origin" }; store.headHash = "fixture-head"; store.headBranch = "feature/42-workspace-search";
  store.inboxDetail = { item: { id: "demo-issue-42", kind: "issue", number: 42, created: Date.parse("2026-10-27T09:00:00Z") / 1000, title: "Make workspace search easier to use", body: "## A faster path to your project\n\nKeep search results clear and make keyboard navigation predictable.\n\n- [x] Group results by repository\n- [ ] Keep the current selection when refreshing", state: "open", author: "demo-maintainer", updated: null, unread: false, url: "https://github.com/sample-studio/desktop/issues/42" }, comments: [{ id: "12", author: "demo-reviewer", body: "The **keyboard shortcuts** feel much clearer now. Could we keep the search query when switching repositories?", date: Date.parse("2026-10-28T09:00:00Z") / 1000 }, { id: "13", author: "demo-maintainer", body: "Yes, that is covered by the linked pull request.\n\n> Keep the query and the active selection together.\n\nI will add the final checks before merging.", date: Date.parse("2026-10-28T10:00:00Z") / 1000, editable: true }], more: false, page: 1 };
  store.issueLinkedRequests = async () => ({ items: [{ id: "demo-pr", number: 58, title: "Preserve search state across repositories", url: "https://github.com/sample-studio/desktop/pull/58", state: "open" }], more: false });
  function IssueDemo() { useObserve(store); return <IssueDetail store={store} detail={store.inboxDetail!}/>; }
  root.style.height = "100vh"; root.style.maxWidth = "760px"; root.style.margin = "0 auto";
  createRoot(root).render(<IssueDemo/>);
} else if (params.get("mode") === "overview") {
  accounts.accounts = [{ id: "overview-demo", provider: "github", server: "https://github.com", username: "demo-reader", name: null, avatarURL: null }];
  accounts.token = async () => "fixture";
  ipc.http = async (_method, url) => ({ status: url.includes("restricted") ? 403 : 200, body: JSON.stringify(url.includes("restricted") ? { message: "Access denied" } : url.includes("library") ? [] : [{ id: 1, tag_name: "v1.10.0", name: "Desktop release", published_at: "2026-10-28T09:00:00Z" }]) });
  workspace.tabs = ["desktop", "library", "restricted"].map(name => {
    const store = new RepoStore(); store.path = `/fixture/${name}`;
    store.target = { provider: "github", host: "github.com", path: `sample-studio/${name}`, remote: "origin" };
    store.navigate = () => true; return store;
  });
  workspace.select = () => {};
  await releasePortfolio.refresh(workspace.tabs, true);
  root.style.padding = "24px";
  createRoot(root).render(<ReleaseOverview/>);
} else if (params.get("mode") !== "demo") {
  const hub = await hostingHubSelfTest();
  const overview = await releaseOverviewSelfTest();
  const issue = await issueWorkflowSelfTest();
  const passed = hub[0] && overview[0] && issue[0], details = hub[1] + "; " + overview[1] + "; " + issue[1];
  const result = document.createElement("pre"); result.id = "release-selftest-result"; result.dataset.passed = String(passed); result.textContent = details; root.append(result);
} else {
  const notes = "## A clearer release workspace\n\nRead **release notes**, compare tags, and find downloads in one place.\n\n### Highlights\n- Markdown reading and live previews\n- [x] Keyboard navigation\n- [x] Independent repository checks\n\n| Platform | Architecture | Status |\n| --- | --- | --- |\n| macOS | Apple silicon / Intel | Ready |\n| Windows | x64 | Ready |\n\n> Check the migration guide before updating a shared workspace.\n\n```sh\nexample-cli --version\n```\n\n[Read the guide](docs/guide.md) · Fixed #42\n\n<details>\n<summary>Compatibility notes</summary>\n\nExisting project files stay compatible.\n</details>";
  const releases = [
    { id: 1, tag_name: "v1.10.0", name: "A clearer release workspace", published_at: "2026-10-28T09:00:00Z", body: notes },
    { id: 2, tag_name: "v1.11.0-rc.1", name: "Next release preview", published_at: "2026-10-27T09:00:00Z", body: notes, prerelease: true },
    { id: 3, tag_name: "v1.9.0", name: "Faster project navigation", published_at: "2026-10-20T09:00:00Z", body: "## Improvements\n\n- Faster project navigation" },
    { id: 4, tag_name: "v1.12.0", name: "Workspace planning", body: "Draft release notes", draft: true },
  ].map(value => ({ ...value, html_url: `https://github.com/sample-studio/desktop/releases/tag/${value.tag_name}`, assets: [{ id: 8, name: "Example-desktop-1.10.0-macOS-universal.zip", size: 12582912, download_count: 142, browser_download_url: "https://github.com/sample-studio/desktop/releases/download/v1.10.0/example.zip" }] }));
  accounts.accounts = [{ id: "release-demo", provider: "github", server: "https://github.com", username: "demo-reader", name: "Demo reader", avatarURL: null }];
  accounts.token = async () => "fixture";
  ipc.http = async (_method, url) => ({ status: 200, body: JSON.stringify(/\/releases\?/.test(url) ? releases : releases.find(item => url.endsWith(`/releases/${item.id}`)) ?? {}) });
  ipc.openUrl = async () => {};
  root.style.height = "100vh";
  createRoot(root).render(<HostingHubPanel section="releases" store={{ path: "/fixture/desktop", headHash: "4f2c9a1e7b3d5f60", headBranch: "main", target: { provider: "github", remote: "origin", host: "github.com", path: "sample-studio/desktop" }, hostingAccount: accounts.accounts[0] }}/>);
}
