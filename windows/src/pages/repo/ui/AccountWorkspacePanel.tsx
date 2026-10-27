import { HostingHubPanel } from "@/widgets/hosting-hub";
import { MyWorkPanel, WorkInboxPanel } from "@/widgets/workspace-panels";
import type { HostingHubSection } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Segmented } from "@/shared/ui";

type AccountSection = "inbox" | "myWork" | HostingHubSection;
const sections: AccountSection[] = ["inbox", "myWork", "organizations"];

/**
 * Everything that belongs to the account rather than the repository, on one page: the inbox and work lists,
 * and the hub's organizations; Releases and Projects have pages of their own (macOS: AccountWorkspacePanel in AccountWorkPanel.swift)
 */
export function AccountWorkspacePanel({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  useObserve(store);
  useObserve(settings);
  const saved = settings.get<string>("accountPageSection", "inbox");
  const section: AccountSection = (sections as string[]).includes(saved) ? (saved as AccountSection) : "inbox";
  const gitlab = store.target?.provider === "gitlab";
  const label = (value: AccountSection) => t(value === "inbox" ? "Inbox" : value === "myWork" ? "My work" : gitlab ? "Groups" : "Organizations");
  return <section className="account-page" aria-label={t("Account")}>
    <div className="account-page-sections">
      <Segmented stretch value={section} onChange={(value) => settings.set("accountPageSection", value)} options={sections.map((value) => ({ value, label: label(value) }))} />
    </div>
    <div className="account-page-body">
      {section === "inbox" ? <WorkInboxPanel store={store} openSettings={openSettings} />
        : section === "myWork" ? <MyWorkPanel store={store} openSettings={openSettings} />
        : <HostingHubPanel store={store} section={section} onClone={(url) => store.openSheet({ kind: "clone", url })} />}
    </div>
  </section>;
}
