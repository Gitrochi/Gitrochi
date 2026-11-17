import { Archive, PanelLeftOpen } from "lucide-react";
import { Cloud, GitBranch, Tag as TagIcon } from "@/shared/icons";
import type { ReactNode } from "react";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { IconButton, tip } from "@/shared/ui";
import { Sidebar, type SidebarSectionID } from "./Sidebar";

/** The sidebar folded away: one icon per section with its count; hovering one opens that section beside it, like GitKraken (macOS: SidebarRail.swift) */
export function SidebarRail({ store }: { store: RepoStore }) {
  useObserve(store);
  const items: { id: Exclude<SidebarSectionID, "repository">; icon: ReactNode; title: string; count: number }[] = [];
  items.push({ id: "local", icon: <GitBranch size={16} />, title: t("Local branches"), count: store.localBranches.length });
  if (store.remoteBranches.length) items.push({ id: "remote", icon: <Cloud size={16} />, title: t("Remotes"), count: store.remoteBranches.length });
  if (store.tags.length) items.push({ id: "tags", icon: <TagIcon size={16} />, title: t("Tags"), count: store.tags.length });
  if (store.stashes.length) items.push({ id: "stashes", icon: <Archive size={16} />, title: t("Stashes"), count: store.stashes.length });
  return (
    <div className="sidebar-rail">
      <IconButton small icon={<PanelLeftOpen size={15} />} tip={tip(t("Show sidebar"), t("Local branches"))} onClick={() => settings.set("sidebarCollapsed", false)} />
      {items.map((it) => (
        <div key={it.id} className="rail-item">
          <div className="rail-icon" aria-label={it.title}>
            {it.icon}
            <span className="rail-count">{it.count}</span>
          </div>
          <div className="rail-flyout">
            <Sidebar store={store} flyout={it.id} />
          </div>
        </div>
      ))}
    </div>
  );
}
