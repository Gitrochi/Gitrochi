import { Archive, CircleDot, Cloud, Folder, GitBranch, GitPullRequest, PanelLeftOpen, Pin, Tag as TagIcon } from "lucide-react";
import type { ReactNode } from "react";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { IconButton, tip } from "@/shared/ui";
import { Sidebar, type SidebarSectionID } from "./Sidebar";

/** The sidebar folded away: one icon per section with its count; hovering one opens that section beside it, like GitKraken (macOS: SidebarRail.swift) */
export function SidebarRail({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  useObserve(store);
  const items: { id: Exclude<SidebarSectionID, "repository">; icon: ReactNode; title: string; count: number | null }[] = [];
  const pinned = store.localBranches.filter((b) => store.isPinned(b)).length;
  if (pinned) items.push({ id: "pinned", icon: <Pin size={16} />, title: t("Pinned"), count: pinned });
  items.push({ id: "local", icon: <GitBranch size={16} />, title: t("Local branches"), count: store.localBranches.length });
  if (store.worktrees.length > 1) items.push({ id: "worktrees", icon: <Folder size={16} />, title: t("Worktrees"), count: store.worktrees.length });
  if (store.remoteBranches.length) items.push({ id: "remote", icon: <Cloud size={16} />, title: t("Remotes"), count: store.remoteBranches.length });
  if (store.target) {
    items.push({
      id: "prs",
      icon: <GitPullRequest size={16} />,
      title: t(store.target.provider === "gitlab" ? "Merge requests" : "Pull requests"),
      count: store.prState.kind === "loaded" ? store.pullRequests.length : null,
    });
    items.push({ id: "issues", icon: <CircleDot size={16} />, title: t("Issues"), count: store.issueState.kind === "loaded" ? store.issues.length : null });
  }
  if (store.tags.length) items.push({ id: "tags", icon: <TagIcon size={16} />, title: t("Tags"), count: store.tags.length });
  if (store.stashes.length) items.push({ id: "stashes", icon: <Archive size={16} />, title: t("Stashes"), count: store.stashes.length });
  return (
    <div className="sidebar-rail">
      <IconButton small icon={<PanelLeftOpen size={15} />} tip={tip(t("Show sidebar"), t("Local branches"))} onClick={() => settings.set("sidebarCollapsed", false)} />
      {items.map((it) => (
        <div key={it.id} className="rail-item">
          <div className="rail-icon" aria-label={it.title}>
            {it.icon}
            {it.count !== null && <span className="rail-count">{it.count}</span>}
          </div>
          <div className="rail-flyout">
            <Sidebar store={store} openSettings={openSettings} flyout={it.id} />
          </div>
        </div>
      ))}
    </div>
  );
}
