import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { avatars } from "@/entities/avatar";
import { accountHost, type HostAccount, type Provider } from "@/entities/git";
import { gitch, type GitchAccount, type GitHubLoginCapability } from "@/entities/gitch";
import { accounts, accountStatusAction } from "@/entities/hosting";
import { AccountAvatar, AccountStatusPill, AddAccountSheet, GitAccountAvatar, GitHubSignInSheet } from "@/features/account-connection";
import { isWindows } from "@/shared/config";
import { Ellipsis, Plus } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Checkbox, IconButton, type MenuItem, SharedSheet, showMenuBelow } from "@/shared/ui";
import { GitchAccountSetup } from "./GitchAccountSetup";
import "./accounts-settings.css";

type AccountsSheet =
  | { kind: "add"; provider?: Provider; server?: string }
  | { kind: "login"; expectedLogin: string; capability: GitHubLoginCapability }
  | { kind: "remove"; account: HostAccount };

/**
 * Settings › Accounts (docs/design.md, App shell): the hosting accounts and the Git identities, each listed once.
 * Accounts are added here or from the account popover, with the same sheet, and removed only here.
 * (macOS: AccountsSettings)
 */
export function AccountsSettings() {
  useObserve(accounts);
  useObserve(avatars);
  const [sheet, setSheet] = useState<AccountsSheet | null>(null);
  const [identities, setIdentities] = useState<GitchAccount[]>([]);
  const [wizard, setWizard] = useState<{ account: GitchAccount | null } | null>(null);
  const [removing, setRemoving] = useState(false);
  const loadIdentities = () => gitch.accounts().then(setIdentities, () => setIdentities([]));
  useEffect(() => { void loadIdentities(); }, []);
  const store = isWindows() ? t("Windows Credential Manager") : t("Keychain");
  const gitHub = (account: HostAccount) => account.provider === "github" && accountHost(account) === "github.com";
  /** github.com accounts renew in the browser; a GitLab server takes a new token in the Add account sheet */
  const resolve = (account: HostAccount) => setSheet(gitHub(account) ? { kind: "login", expectedLogin: account.username, capability: "standard" } : { kind: "add", provider: account.provider, server: account.server });
  const more = (button: HTMLElement, account: HostAccount) => {
    const items: MenuItem[] = [];
    if (gitHub(account)) items.push(
      { label: t("Renew browser connection…"), onClick: () => setSheet({ kind: "login", expectedLogin: account.username, capability: "standard" }) },
      { label: t("Connect project access…"), onClick: () => setSheet({ kind: "login", expectedLogin: account.username, capability: "projects" }) },
    );
    // removing is destructive, so it comes last after a divider and asks first
    items.push({ label: t("Copy username"), onClick: () => void navigator.clipboard.writeText(account.username).catch(() => {}) }, "divider", { label: t("Remove account…"), danger: true, onClick: () => setSheet({ kind: "remove", account }) });
    showMenuBelow(button, items);
  };
  const remove = async (account: HostAccount) => {
    setRemoving(true);
    await accounts.disconnect(account);
    setRemoving(false);
    setSheet(null);
  };

  return (
    <div className="col accounts-settings" style={{ gap: 14 }}>
      <div className="form-section accounts-settings-hosting">
        <div className="row">
          <span className="form-section-title grow">{t("Hosting accounts")}</span>
          <Button className="accounts-settings-add" onClick={() => setSheet({ kind: "add" })}><Plus size={13} />{t("Add account…")}</Button>
        </div>
        {!accounts.accounts.length && <span className="hint">{t("Add a GitHub or GitLab account for pull requests, issues and CI. Commits work without one.")}</span>}
        {accounts.accounts.map((account) => {
          const status = accounts.status(account), action = accountStatusAction(status);
          return (
            <div key={account.id} className="accounts-settings-row" data-account={account.id}>
              <AccountAvatar account={account} size={28} />
              <span className="accounts-settings-text">
                <span className="accounts-settings-title">@{account.username}</span>
                <span className="accounts-settings-caption" title={[accountHost(account), account.name].filter(Boolean).join(" · ")}>{[accountHost(account), account.name].filter(Boolean).join(" · ")}</span>
              </span>
              <AccountStatusPill status={status} />
              {action && <Button onClick={() => resolve(account)}>{action}</Button>}
              <IconButton className="accounts-settings-more" icon={<Ellipsis size={16} />} aria-label={t("More actions for {0}", "@" + account.username)} aria-haspopup="menu" tip={t("More")} onClick={(event) => more(event.currentTarget, account)} />
            </div>
          );
        })}
      </div>

      <div className="form-section accounts-settings-identities">
        <div className="row">
          <span className="form-section-title grow">{t("Git identities")}</span>
          <Button className="accounts-settings-add-identity" onClick={() => setWizard({ account: null })}><Plus size={13} />{t("Add identity…")}</Button>
        </div>
        {!identities.length && <span className="hint">{t("A Git identity is the author name, email and SSH key commits and pushes use.")}</span>}
        {identities.map((identity) => (
          <div key={identity.id} className="accounts-settings-row" data-identity={identity.id}>
            <GitAccountAvatar account={identity} size={28} />
            <span className="accounts-settings-text">
              <span className="accounts-settings-title selectable">{identity.id}{identity.email && <span className="accounts-settings-email">&lt;{identity.email}&gt;</span>}</span>
              <span className="accounts-settings-caption" title={[identity.hosts, identity.rules ?? ""].filter(Boolean).join(" · ")}>{[identity.hosts, identity.rules ?? ""].filter(Boolean).join(" · ")}</span>
            </span>
            <IconButton className="accounts-settings-more" icon={<Ellipsis size={16} />} aria-label={t("More actions for {0}", identity.id)} aria-haspopup="menu" tip={t("More")} onClick={(event) => showMenuBelow(event.currentTarget, [
              { label: t("Connect with SSH…"), onClick: () => setWizard({ account: identity }) },
              { label: t("Copy email"), disabled: !identity.email, onClick: () => void navigator.clipboard.writeText(identity.email).catch(() => {}) },
            ])} />
          </div>
        ))}
        <span className="hint">{t("An account used under several host labels (HTTPS, SSH on port 443) is listed once.")}</span>
      </div>
      {wizard && <GitchAccountSetup key={wizard.account?.id ?? "new"} account={wizard.account} accounts={identities} onSaved={() => void loadIdentities()} onClose={() => setWizard(null)} />}

      <div className="form-section">
        <span className="form-section-title">{t("Commit graph")}</span>
        <Checkbox checked={avatars.enabled} onChange={(v) => avatars.setEnabled(v)} label={t("Show author profile pictures")} />
        <span className="hint">{t("Looks for a GitHub profile, then a connected self-hosted GitLab profile, then Gravatar, and uses initials if none is found. An email hash is sent to Gravatar.")}</span>
      </div>
      <span className="hint">
        {t("Tokens are stored per account in {0} and used to view and create PRs/MRs, list repositories, and authenticate HTTPS push and pull.", store)}</span>

      {sheet?.kind === "add" && createPortal(<AddAccountSheet provider={sheet.provider} server={sheet.server} onClose={() => setSheet(null)} />, document.body)}
      {sheet?.kind === "login" && createPortal(<GitHubSignInSheet expectedLogin={sheet.expectedLogin} capability={sheet.capability} onClose={() => setSheet(null)} />, document.body)}
      {sheet?.kind === "remove" && createPortal(
        <SharedSheet className="remove-account-sheet" title={t("Remove @{0}?", sheet.account.username)} context={accountHost(sheet.account)} width={440} onClose={() => setSheet(null)} cancelDisabled={removing}
          primary={{ label: t("Remove"), busy: removing, onClick: () => void remove(sheet.account) }}>
          <span>{t("Gitrochi forgets this account and deletes its token from {0}. Repositories that used it go back to another account on the same server, if there is one.", store)}</span>
        </SharedSheet>, document.body)}
    </div>
  );
}
