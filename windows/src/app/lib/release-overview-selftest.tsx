import { createRoot } from "react-dom/client";
import { accounts, releasePortfolio } from "@/entities/hosting";
import { RepoStore } from "@/entities/repo";
import { workspace } from "@/entities/workspace";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { ReleaseOverview } from "@/widgets/workspace-panels";

/** The home overview reads independent repositories without changing real tabs or credentials. */
export async function releaseOverviewSelfTest(): Promise<[boolean, string]> {
  const original = { tabs: workspace.tabs, active: workspace.activeId, select: workspace.select, accounts: accounts.accounts, token: accounts.token, http: ipc.http };
  const host = document.createElement("div"); host.hidden = true; document.body.append(host);
  const root = createRoot(host);
  const pause = () => new Promise(resolve => setTimeout(resolve, 25));
  const ensure = (condition: unknown, message: string) => { if (!condition) throw new Error(message); };
  let opened = "", selected = "", requests = 0;
  try {
    accounts.accounts = [{ id: "release-overview-fixture", provider: "github", server: "https://github.com", username: "reader", name: null, avatarURL: null }];
    accounts.token = async () => "fixture";
    const sources = ["desktop", "library", "restricted"].map(name => {
      const store = new RepoStore(); store.path = `C:/release-overview-fixture/${name}`;
      store.target = { provider: "github", remote: "origin", host: "github.com", path: `sample-studio/${name}` };
      store.navigate = page => { opened = `${name}:${page}`; return true; };
      return store;
    });
    workspace.tabs = sources; workspace.activeId = sources[0].id; workspace.select = id => { selected = id; };
    ipc.http = async (_method, url) => {
      requests++;
      if (url.includes("restricted")) return { status: 403, body: '{"message":"Access denied"}' };
      return { status: 200, body: JSON.stringify(url.includes("library") ? [] : [{ id: 1, name: "Desktop", tag_name: "v1.10.0", published_at: "2026-10-28T09:00:00Z" }]) };
    };
    root.render(<ReleaseOverview/>); await pause();
    ensure(requests === 0, "Home contacted a server before Check releases");
    await releasePortfolio.refresh(sources, true); await pause();
    ensure(host.textContent?.includes("v1.10.0"), "Stable version missing");
    ensure(host.textContent?.includes(t("No releases")), "No releases state missing");
    ensure(host.textContent?.includes(t("Access required")), "Repository failure was not isolated");
    host.querySelector<HTMLButtonElement>(".release-overview-card button")!.click();
    ensure(opened === "desktop:releases" && selected === sources[0].id, "Open releases selected a different repository");
    ensure(requests === 3, "Unexpected repository requests");
    return [true, "release overview: explicit reads, stable/no-releases/access states, isolated failures and correct repository navigation"];
  } catch (error) { return [false, error instanceof Error ? error.message : String(error)]; }
  finally { root.unmount(); host.remove(); workspace.tabs = original.tabs; workspace.activeId = original.active; workspace.select = original.select; accounts.accounts = original.accounts; accounts.token = original.token; ipc.http = original.http; }
}
