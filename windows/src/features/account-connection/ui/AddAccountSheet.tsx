import { useState } from "react";
import { accountHost, type HostAccount, type Provider } from "@/entities/git";
import type { GitHubLoginCapability } from "@/entities/gitch";
import { accounts, AccountStore } from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { isWindows } from "@/shared/config";
import { CircleX } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, NoticeBlock, Segmented, SharedSheet } from "@/shared/ui";
import { GitchBrowserLogin } from "./GitchBrowserLogin";
import "./add-account.css";

/** The GitHub account a browser sign-in connected */
const gitHubAccount = (login: string) =>
  accounts.accounts.find((item) => item.provider === "github" && accountHost(item) === "github.com" && item.username.toLowerCase() === login.toLowerCase()) ?? null;

/**
 * Browser sign-in for github.com: a new account, or the named one again (renewing it, or adding project access).
 * It closes once the approved account is connected. (macOS: GitHubBrowserLoginSheet)
 */
export function GitHubSignInSheet({ expectedLogin, capability = "standard", onClose, onConnected }: {
  expectedLogin?: string;
  capability?: GitHubLoginCapability;
  onClose: () => void;
  onConnected?: (account: HostAccount) => void;
}) {
  return (
    <SharedSheet className="github-sign-in-sheet" title={capability === "projects" ? t("Connect GitHub project access") : t("Sign in to GitHub")}
      context={expectedLogin ? `@${expectedLogin} · github.com` : null} width={620} onClose={onClose}>
      <GitchBrowserLogin capability={capability} expectedLogin={expectedLogin} onConnected={(login) => {
        const account = gitHubAccount(login);
        if (account) onConnected?.(account);
        onClose();
      }} />
    </SharedSheet>
  );
}

/**
 * The one way to add a hosting account, opened from the account popover and from Settings › Accounts: GitHub in the
 * browser (or with a token, or the gh command's login), or a self-hosted GitLab server with a token.
 * (macOS: AddAccountSheet)
 */
export function AddAccountSheet({ provider: initialProvider = "github", server: initialServer, onClose, onConnected }: {
  provider?: Provider;
  /** A GitLab server to start from, such as the open repository's */
  server?: string;
  onClose: () => void;
  onConnected?: (account: HostAccount) => void;
}) {
  useObserve(accounts);
  const [provider, setProvider] = useState<Provider>(initialProvider);
  const [browser, setBrowser] = useState(false);
  const [useToken, setUseToken] = useState(false);
  const [githubToken, setGithubToken] = useState("");
  const [gitlabServer, setGitlabServer] = useState(initialServer ?? accounts.suggestedGitLabServer);
  const [gitlabToken, setGitlabToken] = useState("");
  const [working, setWorking] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const run = async (work: () => Promise<HostAccount>) => {
    setWorking(true);
    setError(null);
    try {
      const account = await work();
      onConnected?.(account);
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setWorking(false);
    }
  };
  const choose = (next: Provider) => { setProvider(next); setError(null); };
  const gitlabTokenURL = gitlabServer.trim() ? AccountStore.normalizeServer(gitlabServer) + "/-/user_settings/personal_access_tokens?name=Gitrochi&scopes=api" : null;
  const primary = provider === "gitlab"
    ? { label: t("Connect"), busy: working, disabledReason: gitlabServer.trim() && gitlabToken.trim() ? null : t("Enter the server URL and a token first"), onClick: () => void run(() => accounts.connectGitLab(gitlabServer, gitlabToken)) }
    : useToken
      ? { label: t("Connect"), busy: working, disabledReason: githubToken.trim() ? null : t("Enter a token first"), onClick: () => void run(() => accounts.connectGitHub(githubToken)) }
      : { label: t("Sign in with the browser…"), disabled: working, onClick: () => setBrowser(true) };

  if (browser) return <GitHubSignInSheet onClose={onClose} onConnected={onConnected} />;
  return (
    <SharedSheet className="add-account-sheet" title={t("Add account")} context={t("Pull requests, issues and CI use this account.")} width={520} onClose={onClose} cancelDisabled={working} primary={primary}>
      <Segmented value={provider} onChange={choose} options={[{ value: "github", label: "GitHub" }, { value: "gitlab", label: t("GitLab (self-hosted)") }]} />
      {provider === "github" ? <>
        <span className="hint">{t("github.com opens in your browser to approve access. The token is kept in {0}.", isWindows() ? t("Windows Credential Manager") : t("Keychain"))}</span>
        <button type="button" className="link add-account-toggle" aria-expanded={useToken} onClick={() => { setUseToken(!useToken); setError(null); }}>{t("Use a token instead")}</button>
        {useToken && (
          <label className="add-account-field">
            <span>{t("Personal access token")}</span>
            <input className="input" type="password" value={githubToken} placeholder="ghp_…" onChange={(e) => setGithubToken(e.target.value)} />
            <button type="button" className="link" onClick={() => void ipc.openUrl("https://github.com/settings/tokens/new?scopes=repo,read:org,workflow&description=Gitrochi")}>{t("Create token")}</button>
          </label>
        )}
        {accounts.ghPath && (
          <div className="add-account-import">
            <Button disabled={working} onClick={() => void run(() => accounts.importGitHubCLI())}>{t("Import gh CLI login")}</Button>
            <span className="hint">{t("Uses the account the gh command is signed in to.")}</span>
          </div>
        )}
      </> : <>
        <label className="add-account-field">
          <span>{t("Server URL")}</span>
          <input className="input" value={gitlabServer} placeholder="https://gitlab.example.com" spellCheck={false} onChange={(e) => setGitlabServer(e.target.value)} />
        </label>
        <label className="add-account-field">
          <span>{t("Personal access token (api scope)")}</span>
          <input className="input" type="password" value={gitlabToken} onChange={(e) => setGitlabToken(e.target.value)} />
          {gitlabTokenURL && <button type="button" className="link" onClick={() => void ipc.openUrl(gitlabTokenURL)}>{t("Create token")}</button>}
        </label>
        <span className="hint">{t("Only GitLab servers run by your organization can be connected (gitlab.com isn't supported yet). You can connect several accounts per server.")}</span>
      </>}
      {error && <NoticeBlock className="add-account-error" icon={<CircleX size={14} />} tone="failed" alert title={t("Couldn't add the account")} caption={error} />}
    </SharedSheet>
  );
}
