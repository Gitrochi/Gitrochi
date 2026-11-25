import { useEffect, useState } from "react";
import { accountHost, type HostAccount } from "@/entities/git";
import { defaultGitchFolder, existingGitchAccount, gitch, gitchAccountName, type GitchAccount, type GitchAccountSetup } from "@/entities/gitch";
import { accounts as hostingAccounts, MissingKeyScope } from "@/entities/hosting";
import { workspace } from "@/entities/workspace";
import { GitchBrowserLogin } from "@/features/account-connection";
import { ipc } from "@/shared/api";
import { env, joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, Checkbox, Spinner, tip } from "@/shared/ui";

/**
 * 사람이 누른 저장·키 생성·연결 확인만 실행하는 계정 설정. 기존 계정은 읽기로 시작한다. Started from a saved hosting
 * account (or filled in from one), it fills the details from that account's token, and one action saves the account,
 * creates the key, registers it with the token and checks the connection. (macOS: GitchAccountSetupSheet)
 */
export function GitchAccountSetup({ account, accounts, hosting = null, onSaved, onClose }: { account: GitchAccount | null; accounts: GitchAccount[]; hosting?: HostAccount | null; onSaved: () => void; onClose: () => void }) {
  const [id, setId] = useState("");
  const [email, setEmail] = useState("");
  const [host, setHost] = useState("github.com");
  const [port, setPort] = useState("22");
  const [folder, setFolder] = useState("");
  const [useFolder, setUseFolder] = useState(true);
  const [via, setVia] = useState("");
  const [state, setState] = useState<GitchAccountSetup | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmKey, setConfirmKey] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  /** The saved hosting account the details came from; its token registers the key */
  const [source, setSource] = useState<HostAccount | null>(null);
  const [emailChoices, setEmailChoices] = useState<string[]>([]);
  /** Why the key has to be copied by hand (the token lacks the scope) */
  const [keyNote, setKeyNote] = useState<string | null>(null);

  const run = async (work: () => Promise<unknown>) => {
    setBusy(true); setError(null); setNotice(null);
    try { await work(); } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  };
  useEffect(() => { document.querySelector<HTMLElement>('[aria-label="' + t("Git account setup") + '"]')?.scrollIntoView({ block: "start", behavior: "smooth" }); }, []);
  useEffect(() => {
    if (account) void run(async () => setState(await gitch.inspectAccount(account.id)));
  }, [account]);
  /** Fills the form from a saved hosting account's token: name, server, email choices and the folder rule's default */
  const fill = (from: HostAccount) => run(async () => {
    const found = await hostingAccounts.gitchEmails(from);
    const server = accountHost(from);
    setSource(from); setId(gitchAccountName(from.username, server, accounts)); setHost(server); setPort("22");
    setEmailChoices(found); setEmail(found[0] ?? "");
    const parent = defaultGitchFolder(workspace.tabs.filter((tab) => tab.path).map((tab) => ({ path: tab.path!, host: tab.target?.host ?? null })), server, env.home);
    setUseFolder(!!parent); setFolder(parent ?? "");
  });
  useEffect(() => { if (hosting) void fill(hosting); }, [hosting]);
  /** Registers the key with the saved token and checks the connection; a token without the scope leaves the copy step with the reason */
  const register = async (current: GitchAccountSetup, from: HostAccount) => {
    try {
      const created = await hostingAccounts.registerSSHKey(from, current.ssh.publicKey ?? "", `Gitrochi (${current.account.id})`);
      setKeyNote(null);
      setNotice(created ? t("Public key registered with {0}.", accountHost(from)) : t("This public key is already registered with {0}.", accountHost(from)));
    } catch (e) {
      if (e instanceof MissingKeyScope) { setKeyNote(e.message); return; }
      throw e;
    }
    setState(await gitch.checkAccountConnection(current.account.id));
    onSaved();
  };
  /** Saves (or reuses) the gitch account, creates its key when missing, then registers it */
  const connect = (from: HostAccount) => run(async () => {
    const existing = existingGitchAccount(id.trim(), host.trim(), accounts);
    let current = existing ? await gitch.inspectAccount(existing.id) : await gitch.addAccount({ id: id.trim(), email: email.trim(), host: host.trim(), port: +port, folder: useFolder && folder ? folder : null, via: null });
    setState(current); onSaved();
    if (!current.ssh.keyExists || current.ssh.aliasConfigured === false) { current = await gitch.generateAccountKey(current.account.id); setState(current); onSaved(); }
    await register(current, from);
  });
  const valid = /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id.trim()) && /^[^\s@]+@[^\s@]+$/.test(email.trim()) && /^[A-Za-z0-9][A-Za-z0-9.-]*$/.test(host.trim()) && /^\d+$/.test(port) && +port > 0 && +port <= 65535;
  const destination = folder || joinPath(env.home, "Develop", id.trim() || "account");
  const save = () => run(async () => {
    setState(await gitch.addAccount({ id: id.trim(), email: email.trim(), host: host.trim(), port: +port, folder: useFolder ? destination : null, via: via || null }));
    onSaved();
  });

  return (
    <div className="form-section" style={{ gap: 12, padding: 14 }} aria-label={t("Git account setup")}>
      <div className="row"><strong className="grow">{t("Git account setup")}</strong><Button disabled={busy} size="small" onClick={onClose}>{t("Close")}</Button></div>
      <div className="hint">{t("1. Account details → 2. Register SSH key → 3. Test connection")}</div>
      {!state && !account && source && <>
        <strong>@{source.username}</strong>
        <label className="col" style={{ gap: 4 }}>{t("Account username")}<input className="input" value={id} onChange={(e) => setId(e.target.value)} autoComplete="off" spellCheck={false} disabled={busy} /></label>
        <label className="col" style={{ gap: 4 }}>{t("Commit email")}{emailChoices.length > 1
          ? <select className="select" value={email} onChange={(e) => setEmail(e.target.value)} disabled={busy}>{emailChoices.map((e) => <option key={e} value={e}>{e}</option>)}</select>
          : <input className="input" type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@example.com" disabled={busy} />}</label>
        <div className="row" style={{ alignItems: "end" }}>
          <span className="col grow" style={{ gap: 4 }}>{t("Git server")}<span className="muted selectable">{host}</span></span>
          <label className="col" style={{ width: 90, gap: 4 }}>{t("SSH port")}<input className="input" type="number" min="1" max="65535" value={port} onChange={(e) => setPort(e.target.value)} disabled={busy} /></label>
        </div>
        <Checkbox checked={useFolder} onChange={setUseFolder} disabled={busy} label={t("Choose this account automatically for a folder")} />
        {useFolder && <div className="row"><input className="input grow" aria-label={t("Account folder")} value={folder} onChange={(e) => setFolder(e.target.value)} disabled={busy} /><Button disabled={busy} onClick={() => void run(async () => { const p = await ipc.pickFolder(t("Account folder"), env.home); if (p) setFolder(p); })}>{t("Browse…")}</Button></div>}
        <span className="hint">{t("Defaults to the folder that holds an open repository from this server.")}</span>
        <span className="hint">{t("Saves this account and the folder rule in gitch, creates an SSH key on this computer if there is none, registers its public key with {0} using the saved sign-in, and checks the connection. The token and the private key are not stored in gitch.", host)}</span>
        <Button kind="primary" disabled={!valid || (useFolder && !folder) || busy} onClick={() => void connect(source)}>{t("Connect to gitch")}</Button>
      </>}
      {!state && !account && !source && <>
        {hostingAccounts.accounts.length > 0 && <label className="col" style={{ gap: 4 }}>{t("Fill in from a saved account")}<select className="select" value="" disabled={busy} onChange={(e) => { const from = hostingAccounts.accounts.find((a) => a.id === e.target.value); if (from) void fill(from); }}><option value="">—</option>{hostingAccounts.accounts.map((a) => <option key={a.id} value={a.id}>@{a.username} · {accountHost(a)}</option>)}</select><span className="hint">{t("Uses the account's saved sign-in for the name, email and server, and to register the SSH key.")}</span></label>}
        <GitchBrowserLogin onConnected={(login, address) => { const existing = accounts.find((a) => a.id.toLowerCase() === login.toLowerCase() && a.hosts.split(",").some((server) => server.split("(")[0].trim().toLowerCase() === "github.com")); if (existing) { void run(async () => setState(await gitch.inspectAccount(existing.id))); } else { setId(login); setEmail(address); setHost("github.com"); setPort("22"); setNotice(t("Account details filled in. Review and save to continue.")); } }} />
        <span className="hint">{t("Use the username and commit email for your GitHub or GitLab account. This is gitch add, with a form instead of terminal questions.")}</span>
        <label className="col" style={{ gap: 4 }}>{t("Account username")}<input className="input" value={id} onChange={(e) => setId(e.target.value)} placeholder="octocat" autoComplete="off" spellCheck={false} disabled={busy} /></label>
        <label className="col" style={{ gap: 4 }}>{t("Commit email")}<input className="input" type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@example.com" disabled={busy} /></label>
        <div className="row" style={{ alignItems: "end" }}>
          <label className="col grow" style={{ gap: 4 }}>{t("Git server")}<input className="input" value={host} onChange={(e) => setHost(e.target.value)} placeholder="github.com / gitlab.example.com" spellCheck={false} disabled={busy} /></label>
          <label className="col" style={{ width: 90, gap: 4 }}><span className="row" style={{ gap: 4 }}>{t("SSH port")}<button type="button" className="link" aria-label={t("What is an SSH port?")} title={t("The number used to connect to your Git server over SSH. Usually 22. For a company or self-hosted server, enter the number your administrator gave you, such as 2222. This is separate from the website address.")} data-tip={tip(t("What is an SSH port?"), t("The number used to connect to your Git server over SSH. Usually 22. For a company or self-hosted server, enter the number your administrator gave you, such as 2222. This is separate from the website address."))}>?</button></span><input className="input" type="number" min="1" max="65535" value={port} onChange={(e) => setPort(e.target.value)} disabled={busy} /></label>
        </div>
        <Checkbox checked={useFolder} onChange={setUseFolder} disabled={busy} label={t("Choose this account automatically for a folder")} />
        {useFolder && <div className="row"><input className="input grow" aria-label={t("Account folder")} value={folder} placeholder={destination} onChange={(e) => setFolder(e.target.value)} disabled={busy} /><Button disabled={busy} onClick={() => void run(async () => { const p = await ipc.pickFolder(t("Account folder"), env.home); if (p) setFolder(p); })}>{t("Browse…")}</Button></div>}
        {accounts.length > 0 && <label className="col" style={{ gap: 4 }}>{t("SSH login")}<select className="select" value={via} onChange={(e) => setVia(e.target.value)} disabled={busy}><option value="">{t("Use a separate SSH key for this account")}</option>{accounts.map((a) => <option key={a.id} value={a.id}>{t("Use the existing login: {0}", a.id)}</option>)}</select><span className="hint">{t("Choose an existing login only when both identities intentionally share the same server login.")}</span></label>}
        <div className="hint">{t("Saving adds this account to ~/.config/gitch/config and prepares the selected folder. SSH keys, shell integration and global Git settings are separate steps.")}</div>
        <Button kind="primary" disabled={!valid || busy} onClick={() => void save()}>{t("Save account and continue")}</Button>
      </>}
      {state && <>
        {state.account.host === "github.com" && <details><summary>{t("Connect or renew browser login for this account")}</summary><div style={{ paddingTop: 8 }}><GitchBrowserLogin expectedLogin={state.account.id} onConnected={() => setNotice(t("Browser account connected. You can now register the public key automatically."))} /></div></details>}
        <div className="row"><strong>{state.account.id}</strong><span className="muted selectable">{state.account.email} · {state.account.host}:{state.account.port}</span></div>
        {state.ssh.authenticated === true ? <span style={{ color: "var(--green)" }}>{t("Connection verified. This account is ready.")}</span> : <span className="hint">{t("The account is saved. Register the public key below with the same account on your Git server, then test the connection.")}</span>}
        {state.ssh.keyExists && state.ssh.aliasConfigured === false && <div className="form-section" style={{ gap: 8 }}><span className="hint">{t("An SSH key exists, but this account's connection alias is missing. Add the alias to ~/.ssh/config with a backup; the existing key is preserved.")}</span><Button disabled={busy} onClick={() => void run(async () => { setState(await gitch.generateAccountKey(state.account.id)); onSaved(); })}>{t("Set up connection for the existing key")}</Button></div>}
        {!state.ssh.keyExists ? <>
          <span className="hint">{t("Gitrochi can create a separate SSH key on this computer. The private key stays here; only the public key is shown.")}</span>
          {!confirmKey ? <Button disabled={busy} onClick={() => setConfirmKey(true)}>{t("Create SSH key…")}</Button> : <div className="form-section" style={{ gap: 8 }}>
            <span className="hint">{t("Create a dedicated Ed25519 key without a passphrase? It will be saved with private file permissions and will not replace an existing key. For a passphrase-protected key, use the advanced terminal setup.")}</span>
            <div className="row"><Button disabled={busy} onClick={() => setConfirmKey(false)}>{t("Cancel")}</Button><Button kind="primary" disabled={busy} onClick={() => void run(async () => { setState(await gitch.generateAccountKey(state.account.id)); setConfirmKey(false); onSaved(); })}>{t("Create dedicated key")}</Button></div>
          </div>}
        </> : <>
          <span className="hint">{t("Public SSH key — safe to copy to your Git server")}</span>
          <textarea className="textarea mono selectable" aria-label={t("Public SSH key")} readOnly value={state.ssh.publicKey ?? ""} rows={4} style={{ fontSize: 11, overflowWrap: "anywhere" }} />
          <div className="row" style={{ flexWrap: "wrap" }}>
            <Button disabled={busy || !state.ssh.publicKey} onClick={() => void run(async () => { await navigator.clipboard.writeText(state.ssh.publicKey!); setNotice(t("Public key copied")); })}>{t("Copy public key")}</Button>
            <Button disabled={busy} onClick={() => void run(() => ipc.openUrl(state.ssh.registrationURL))}>{t("Open SSH key registration")}</Button>
            {source && accountHost(source) === state.account.host.toLowerCase()
              ? <Button disabled={busy || !state.ssh.publicKey} onClick={() => void run(() => register(state, source))}>{t("Register key with {0}…", accountHost(source))}</Button>
              : state.account.host === "github.com" && <Button disabled={busy || !state.ssh.publicKey} onClick={() => void run(async () => { await hostingAccounts.registerGitHubSSHKey(state.account.id, state.ssh.publicKey!); setState(await gitch.checkAccountConnection(state.account.id)); onSaved(); })}>{t("Register key automatically and connect")}</Button>}
            <Button kind="primary" disabled={busy} onClick={() => void run(async () => { setState(await gitch.checkAccountConnection(state.account.id)); onSaved(); })}>{t("Test connection")}</Button>
          </div>
          {keyNote && <span className="error-text" role="status">{keyNote}</span>}
          {state.ssh.message && <span className="hint selectable">{state.ssh.message}</span>}
        </>}
        <details><summary>{t("Advanced terminal setup")}</summary><div className="col" style={{ gap: 6, paddingTop: 8 }}><span className="hint">{t("Use this for a passphrase-protected key or a custom SSH setup. Return here and refresh after finishing.")}</span><div className="row"><Button disabled={busy} onClick={() => void run(() => gitch.openInConsole(["setup", state.account.id]))}>{t("Open advanced setup")}</Button><Button disabled={busy} onClick={() => void run(async () => { setState(await gitch.inspectAccount(state.account.id)); onSaved(); })}>{t("Refresh")}</Button></div></div></details>
      </>}
      {busy && <span className="row" role="status"><Spinner />{t("Working…")}</span>}
      {notice && <span role="status" style={{ color: "var(--green)" }}>{notice}</span>}
      {error && <span className="error-text selectable" role="alert" style={{ whiteSpace: "pre-wrap" }}>{error}</span>}
      {!state && account && !busy && error && <Button onClick={() => void run(async () => setState(await gitch.inspectAccount(account.id)))}>{t("Retry")}</Button>}
    </div>
  );
}
