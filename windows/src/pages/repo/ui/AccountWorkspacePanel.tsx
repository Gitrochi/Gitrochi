import { useState } from "react";
import { ChevronDown, RefreshCw, UserRound } from "lucide-react";
import { HostingHubPanel } from "@/widgets/hosting-hub";
import { MyWorkPanel, WorkInboxPanel } from "@/widgets/workspace-panels";
import { AccountState, AccountWorkModel, SignInExpired } from "@/features/account-work";
import { accountHost, type HostAccount } from "@/entities/git";
import { accounts, HostingError } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Avatar, Button, showMenuBelow, Spinner } from "@/shared/ui";
import "./account-page.css";

type AccountSection = "inbox" | "myWork" | "organizations";
const sections: AccountSection[] = ["inbox", "myWork", "organizations"];
const accountTitle = (account: HostAccount) => `${accountHost(account)} · @${account.username}`;

/**
 * The Account page, as the redesign's Account board draws it: underline tabs for the Inbox, My work and the
 * organizations, one row that chooses the account and refreshes, then a list column with the selected item beside it.
 * Releases and Projects have pages of their own. (macOS: AccountWorkspacePanel)
 */
export function AccountWorkspacePanel({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  const hub = store.hostingHub;
  useObserve(store);
  useObserve(hub);
  useObserve(settings);
  useObserve(accounts);
  const [inbox] = useState(() => new AccountWorkModel(true));
  const [work] = useState(() => new AccountWorkModel(false));
  useObserve(inbox);
  useObserve(work);
  const saved = settings.get<string>("accountPageSection", "inbox");
  // a section saved by an older version (Releases, Projects) opens the inbox
  const section: AccountSection = (sections as string[]).includes(saved) ? (saved as AccountSection) : "inbox";
  // The chosen account, else the open repository's, else the first one: the rule the organizations already follow
  // (HostingHubStore.account), so the three sections always show the same account
  const account = accounts.accounts.find((value) => value.id === hub.selectedAccountID) ?? store.hostingAccount ?? accounts.accounts[0] ?? null;
  const gitlab = (account?.provider ?? store.target?.provider) === "gitlab";
  const label = (value: AccountSection) => t(value === "inbox" ? "Inbox" : value === "myWork" ? "My work" : gitlab ? "Groups" : "Organizations");
  const hubLocked = hub.busy || hub.loading || hub.detailLoading;
  const busy = section === "organizations" ? hubLocked : section === "myWork" ? work.busy : inbox.busy;
  // the hub keeps its errors as text, so an expired sign-in is the text a 401 becomes
  const hubExpired = section === "organizations" && hub.error === HostingError.describe(401, "");
  // choosing here never changes the Git identity of a repository; the organizations reload through the hub
  const choose = (id: string) => {
    if (section === "organizations") void hub.selectAccount(id);
    else { hub.selectedAccountID = id; store.changed(); }
  };
  const refresh = () => {
    if (!account) return;
    if (section === "organizations") void hub.load();
    else void (section === "myWork" ? work : inbox).load(account);
  };
  return (
    <section className="account-page" aria-label={t("Account")}>
      <nav className="account-tabs" role="tablist" aria-label={t("Account sections")}>
        {sections.map((value) => (
          <button key={value} type="button" role="tab" aria-selected={section === value} className={`account-tab${section === value ? " on" : ""}`} onClick={() => settings.set("accountPageSection", value)}>{label(value)}</button>
        ))}
        <span className="grow" />
        {section === "inbox" && account && <button type="button" className="account-text-button" disabled={inbox.busy || !inbox.unread.length} onClick={() => void inbox.readAll(account)}>{t("Mark all as read")}</button>}
      </nav>
      {account ? <>
        <div className="account-toolbar">
          <Button className="account-picker" aria-haspopup="menu" aria-label={t("Account and server")} disabled={section === "organizations" && hubLocked}
            onClick={(event) => showMenuBelow(event.currentTarget, [
              ...accounts.accounts.map((value) => ({ label: accountTitle(value), checked: value.id === account.id, onClick: () => choose(value.id) })),
              "divider" as const,
              { label: t("Account settings…"), onClick: openSettings },
            ])}>
            <Avatar name={account.name ?? account.username} email={account.username} url={account.avatarURL} size={20} />
            <span className="ellipsis">{accountTitle(account)}</span>
            <ChevronDown size={12} />
          </Button>
          <Button className="account-icon-button" tip={t("Refresh")} aria-label={t("Refresh")} disabled={busy} onClick={refresh}><RefreshCw size={14} /></Button>
          {busy && <Spinner size={12} />}
        </div>
        <div className="account-page-body">
          {section === "inbox" ? <WorkInboxPanel store={store} model={inbox} account={account} openSettings={openSettings} />
            : section === "myWork" ? <MyWorkPanel store={store} model={work} account={account} openSettings={openSettings} />
            : <>
              {hubExpired && <SignInExpired account={account} openSettings={openSettings} />}
              {/* the hub stays mounted while hidden, so signing in again reloads it */}
              <div className="account-page-hub" hidden={hubExpired}>
                <HostingHubPanel store={store} section="organizations" onClone={(url) => store.openSheet({ kind: "clone", url })} />
              </div>
            </>}
        </div>
      </> : (
        // blocked: nothing on this page works without an account, so its one action is filled
        <AccountState icon={<UserRound size={24} />} title={t("No account")} caption={t("Add a GitHub or GitLab account for pull requests, issues and CI. Commits work without one.")} action={t("Connect account…")} filled onAction={openSettings} />
      )}
    </section>
  );
}
