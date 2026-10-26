import { CircleCheck } from "lucide-react";
import { useState } from "react";
import { avatars } from "@/entities/avatar";
import { accountHost, type HostAccount, type Provider } from "@/entities/git";
import { accounts, AccountStore } from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { isWindows } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Avatar, Button, Checkbox, Spinner } from "@/shared/ui";
import { GitchBrowserLogin } from "./GitchBrowserLogin";

export function AccountConnections() {
  useObserve(accounts);
  useObserve(avatars);
  const [githubToken, setGithubToken] = useState("");
  const [gitlabServer, setGitlabServer] = useState(accounts.suggestedGitLabServer);
  const [gitlabToken, setGitlabToken] = useState("");
  const [working, setWorking] = useState<Provider | null>(null);
  const [error, setError] = useState<string | null>(null);

  const run = async (p: Provider, work: () => Promise<unknown>) => {
    setWorking(p);
    setError(null);
    try {
      await work();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
    setWorking(null);
  };
  const count = (p: Provider) => (accounts.accountsFor(p).length ? t(" · {0}", accounts.accountsFor(p).length) : "");
  const gitlabTokenURL = gitlabServer.trim() ? AccountStore.normalizeServer(gitlabServer) + "/-/user_settings/personal_access_tokens?name=Gitrochi&scopes=api" : null;

  return (
    <div className="col" style={{ gap: 14 }}>
      <GitchBrowserLogin />
      <div className="form-section">
        <span className="form-section-title">GitHub{count("github")}</span>
        {accounts.accountsFor("github").map((a) => (
          <ConnectedRow key={a.id} account={a} />
        ))}
        <input
          className="input"
          type="password"
          value={githubToken}
          placeholder={accounts.accountsFor("github").length ? t("Another account's token") : "Personal access token (ghp_…)"}
          onChange={(e) => setGithubToken(e.target.value)}
        />
        <div className="row">
          <Button
            disabled={!githubToken.trim() || !!working}
            onClick={() =>
              void run("github", async () => {
                await accounts.connectGitHub(githubToken);
                setGithubToken("");
              })
            }
          >
            {accounts.accountsFor("github").length ? t("Add account") : t("Connect")}
          </Button>
          {accounts.ghPath && (
            <Button disabled={!!working} onClick={() => void run("github", () => accounts.importGitHubCLI())}>
              {t("Import gh CLI login")}</Button>
          )}
          {working === "github" && <Spinner />}
          <span className="spacer" />
          <button className="link" onClick={() => void ipc.openUrl("https://github.com/settings/tokens/new?scopes=repo,read:org,workflow&description=Gitrochi")}>
            {t("Create token")}</button>
        </div>
        <span className="hint">{t("If you connect several accounts, you can choose which one to use above the PR list for repositories on the same server.")}</span>
      </div>

      <div className="form-section">
        <span className="form-section-title">{t("Self-hosted GitLab{0}", count("gitlab"))}</span>
        {accounts.accountsFor("gitlab").map((a) => (
          <ConnectedRow key={a.id} account={a} showServer />
        ))}
        <input className="input" value={gitlabServer} placeholder={t("Server address — https://gitlab.example.com")} onChange={(e) => setGitlabServer(e.target.value)} spellCheck={false} />
        <input className="input" type="password" value={gitlabToken} placeholder={t("Personal access token (api scope)")} onChange={(e) => setGitlabToken(e.target.value)} />
        <div className="row">
          <Button
            disabled={!gitlabServer.trim() || !gitlabToken.trim() || !!working}
            onClick={() =>
              void run("gitlab", async () => {
                await accounts.connectGitLab(gitlabServer, gitlabToken);
                setGitlabToken("");
              })
            }
          >
            {accounts.accountsFor("gitlab").length ? t("Add account") : t("Connect")}
          </Button>
          {working === "gitlab" && <Spinner />}
          <span className="spacer" />
          {gitlabTokenURL && (
            <button className="link" onClick={() => void ipc.openUrl(gitlabTokenURL)}>
              {t("Create token")}</button>
          )}
        </div>
        <span className="hint">{t("Only GitLab servers run by your organization can be connected (gitlab.com isn't supported yet). You can connect several accounts per server.")}</span>
      </div>

      <div className="form-section">
        <span className="form-section-title">{t("Commit graph")}</span>
        <Checkbox checked={avatars.enabled} onChange={(v) => avatars.setEnabled(v)} label={t("Show author profile pictures")} />
        <span className="hint">{t("Looks for a GitHub profile, then a connected self-hosted GitLab profile, then Gravatar, and uses initials if none is found. An email hash is sent to Gravatar.")}</span>
      </div>
      {error && <span className="error-text">{error}</span>}
      <span className="hint">
        {t("Tokens are stored per account in {0} and used to view and create PRs/MRs, list repositories, and authenticate HTTPS push and pull.", isWindows() ? t("Windows Credential Manager") : t("Keychain"))}</span>
    </div>
  );
}

function ConnectedRow({ account: a, showServer }: { account: HostAccount; showServer?: boolean }) {
  return (
    <div className="row" style={{ gap: 10 }}>
      <Avatar name={a.name ?? a.username} email={a.username} size={30} url={a.avatarURL} />
      <div className="col grow">
        <span style={{ fontWeight: 500 }}>{a.name ?? a.username}</span>
        <span className="muted" style={{ fontSize: 11.5 }}>
          @{a.username}
          {showServer ? ` · ${accountHost(a)}` : ""}
        </span>
      </div>
      <span className="row" style={{ color: "var(--green)", fontSize: 12 }}>
        <CircleCheck size={13} /> {" "}{t("Connected")}</span>
      <Button size="small" onClick={() => void accounts.disconnect(a)}>
        {t("Disconnect")}</Button>
    </div>
  );
}
