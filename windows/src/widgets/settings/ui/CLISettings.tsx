import { useCallback, useEffect, useRef, useState } from "react";
import { Copy } from "lucide-react";
import { gitch, type GitchAccount, type GitchDoctor } from "@/entities/gitch";
import { displayPath, env, slash } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, Checkbox, Segmented, Spinner } from "@/shared/ui";
import { GitchAccountSetup } from "./GitchAccountSetup";
import { GitchGuide } from "./GitchGuide";

interface Info {
  bundledVersion: string | null;
  installed: { name: string; path: string; version: string | null } | null;
  installedIsBundled: boolean;
  hasConfig: boolean;
  bash: string | null;
  accounts: GitchAccount[];
}

/** 홈 폴더를 ~ 로(설치 위치를 짧게) */
function tilde(p: string) {
  const home = slash(env.home).toLowerCase();
  const s = slash(p);
  return home && s.toLowerCase().startsWith(home) ? "~" + s.slice(home.length) : displayPath(p);
}

/**
 * 설정 > CLI 의 gitch(예전 이름 gitsw): 앱에 든 gitch 를 셸 명령으로 설치한다. (맥 버전 GitchSettings)
 * 계정과 SSH 설정은 앱에서 명시적으로 저장·생성·연결 확인한다.
 */
export function CLISettings({ initialMode = "setup" }: { initialMode?: "setup" | "guide" } = {}) {
  const [panel, setPanel] = useState<"setup" | "guide">(initialMode);
  const [wizard, setWizard] = useState<{ account: GitchAccount | null } | null>(null);
  const [diagnosis, setDiagnosis] = useState<GitchDoctor | null>(null);
  const [info, setInfo] = useState<Info | null>(null);
  const [confirmInstall, setConfirmInstall] = useState(false);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const [logoEnabled, setLogoEnabled] = useState<boolean | null>(null);
  const [logoBusy, setLogoBusy] = useState(false);
  const [logoError, setLogoError] = useState<string | null>(null);
  const logoRequest = useRef(0);
  const logoSaving = useRef(false);

  const loadLogo = useCallback(async () => {
    if (logoSaving.current) return;
    const request = ++logoRequest.current;
    setLogoBusy(true);
    try {
      const enabled = await gitch.logo();
      if (request === logoRequest.current) { setLogoEnabled(enabled); setLogoError(null); }
    } catch (e) {
      if (request === logoRequest.current) setLogoError(e instanceof Error ? e.message : String(e));
    } finally {
      if (request === logoRequest.current) setLogoBusy(false);
    }
  }, []);

  const setLogo = async (enabled: boolean) => {
    if (logoSaving.current) return;
    logoSaving.current = true;
    const request = ++logoRequest.current;
    setLogoBusy(true);
    setLogoError(null);
    try {
      const saved = await gitch.setLogo(enabled);
      if (request === logoRequest.current) setLogoEnabled(saved);
    } catch (e) {
      if (request === logoRequest.current) setLogoError(e instanceof Error ? e.message : String(e));
    } finally {
      logoSaving.current = false;
      if (request === logoRequest.current) setLogoBusy(false);
    }
  };

  const load = useCallback(async () => {
    void loadLogo();
    const bundled = gitch.bundled;
    const [bundledVersion, installed, installedIsBundled, hasConfig, bash, accounts] = await Promise.all([
      bundled ? gitch.version(bundled) : Promise.resolve(null),
      gitch.installed(),
      gitch.installedIsBundled(),
      gitch.hasConfig(),
      gitch.bash(),
      gitch.accounts(),
    ]);
    setInfo({ bundledVersion, installed: installed && { ...installed, version: await gitch.version(installed.path) }, installedIsBundled, hasConfig, bash, accounts });
  }, [loadLogo]);
  // 다른 창에서 설정을 바꾸고 돌아왔을 때에도 다시 읽는다
  useEffect(() => {
    void load();
    const onFocus = () => void load();
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [load]);

  const run = async (action: () => Promise<void>) => {
    setError(null);
    try {
      await action();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };
  const install = async () => {
    setConfirmInstall(false);
    setBusy(true);
    setError(null);
    setResult(null);
    try {
      // 마지막 몇 줄(설치 완료 안내)만 보여 준다
      setResult((await gitch.install()).split("\n").slice(-6).join("\n"));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
    setBusy(false);
    void load();
  };

  if (!info) {
    return (
      <div className="row" style={{ justifyContent: "center", padding: 40 }}>
        <Spinner />
      </div>
    );
  }
  const status = !info.installed ? (
    <span className="faint">{t("Terminal command is optional")}</span>
  ) : info.installedIsBundled ? (
    <span className="chip-warn" style={{ color: "var(--accent)", background: "var(--accent-soft)" }}>
      {t("Installed")}
    </span>
  ) : (
    <span className="faint" style={{ fontSize: 11 }}>{t("Installed from another copy")}</span>
  );
  const hasAccounts = info.hasConfig && info.accounts.length > 0;
  return (
    <div className="col" style={{ gap: 10 }}>
      {/* the guide and the read-only diagnosis live here, next to the account setup they explain */}
      <Segmented value={panel} onChange={setPanel} options={[{ value: "setup", label: t("Account setup") }, { value: "guide", label: t("Getting started and commands") }]} />
      {panel === "guide" ? <GitchGuide onAddAccount={() => { setPanel("setup"); setWizard({ account: null }); }} onDoctor={() => { setPanel("setup"); void run(async () => setDiagnosis(await gitch.doctor())); }} /> : <>
      <div className="form-section" style={{ gap: 8, padding: 12 }}>
        <span className="form-section-title">{t("CLI appearance")}</span>
        <div className="row">
          <Checkbox checked={logoEnabled ?? true} disabled={logoBusy || logoEnabled === null || !info.bash} onChange={(enabled) => void setLogo(enabled)} label={t("Show the small eye logo in CLI output")} />
          {logoBusy && <Spinner size={13} />}
        </div>
        <span className="hint">{t("You can also use gitch logo on or gitch logo off in a terminal.")}</span>
        {logoError && <div className="col" style={{ gap: 6 }}>
          <span className="error-text selectable" role="alert" style={{ whiteSpace: "pre-wrap" }}>{logoError}</span>
          <Button size="small" disabled={logoBusy || !info.bash} onClick={() => void loadLogo()}>{t("Retry")}</Button>
        </div>}
      </div>
      <CLIWorkflowGuide />
      <div className="form-section" style={{ gap: 8, padding: 12 }}>
        <div className="row">
          <span style={{ fontWeight: 600 }}>gitch</span>
          <span className="spacer" />
          {status}
        </div>
        <span className="hint">{t("gitch is already included in this app. Add your Git identity below; no separate CLI download is needed.")}</span>
        <span className="hint">
          {t("gitch keeps several Git accounts apart: it locks each repository to an account, picks the account by folder or organization, and blocks wrong authors, secrets and force pushes in git hooks, in the terminal, for AI agents and in Gitrochi.")}
        </span>
        <Field label={t("Version in Gitrochi")}>{info.bundledVersion ?? "—"}</Field>
        <Field label={t("Shell command")}>
          {info.installed ? `${info.installed.name} → ${tilde(info.installed.path)}${info.installed.version ? ` (${info.installed.version})` : ""}` : "—"}
        </Field>
        <Field label="Git Bash">{info.bash ? displayPath(info.bash) : "—"}</Field>
        <Field label={t("Accounts")}>{info.accounts.length ? String(info.accounts.length) : t("None yet")}</Field>
        {info.accounts.map((a) => (
          <div key={a.id} className="row" style={{ alignItems: "flex-start", paddingLeft: 4 }}>
            <div className="col grow" style={{ gap: 2, minWidth: 0 }}>
              <div className="row" style={{ gap: 6 }}>
                <span style={{ fontWeight: 600 }}>{a.id}</span>
                <span className="muted ellipsis">{a.email}</span>
              </div>
              <span className="faint" style={{ fontSize: 11.5 }}>
                {[a.hosts, a.rules ?? ""].filter(Boolean).join(" · ")}
              </span>
            </div>
            {(
              <Button size="small" onClick={() => setWizard({ account: a })}>
                {t("SSH setup / Test connection")}
              </Button>
            )}
          </div>
        ))}
        {!info.bash && (
          <span className="error-text">
            {t("gitch needs Git for Windows (Git Bash). Install it from https://git-scm.com/download/win.")}
          </span>
        )}
        <div className="row" style={{ flexWrap: "wrap" }}>
          <Button disabled={!info.bash} onClick={() => setWizard({ account: null })}>
            {t("Add account")}
          </Button>
          <Button kind="primary" disabled={!hasAccounts || busy || !info.bundledVersion || !info.bash} onClick={() => setConfirmInstall(true)}>
            {info.installedIsBundled ? t("Reinstall terminal integration…") : t("Enable terminal command…")}
          </Button>

          <span className="spacer" />
          {busy && <Spinner size={13} />}
        </div>
        {confirmInstall && (
          <div className="form-section" style={{ gap: 8, padding: 10 }}>
            <span style={{ fontWeight: 600 }}>{t("Install gitch?")}</span>
            <span className="hint" style={{ whiteSpace: "pre-wrap" }}>
              {t(
                "This changes files outside Gitrochi, backing them up first:\n• ~/bin/gitch and the old name ~/bin/gitsw: link to the gitch inside Gitrochi (and gitch.cmd for PowerShell and cmd; ~/bin is added to your user PATH)\n• ~/.bashrc: adds a gitch block for Git Bash\n• ~/.gitconfig: global hooks that check authors, secrets, big files and force pushes, and rules that pick the account\n• ~/.claude and ~/.codex: rules, skills and a hook for AI agents\nRemove it later with gitch uninstall.",
              )}
            </span>
            <div className="row">
              <span className="spacer" />
              <Button onClick={() => setConfirmInstall(false)}>{t("Cancel")}</Button>
              <Button kind="primary" onClick={() => void install()}>
                {t("Install")}
              </Button>
            </div>
          </div>
        )}
        {result && (
          <pre className="mono selectable muted" style={{ fontSize: 11.5, whiteSpace: "pre-wrap", margin: 0 }}>
            {result}
          </pre>
        )}
        {error && <span className="error-text selectable" style={{ whiteSpace: "pre-wrap" }}>{error}</span>}
        <span className="hint">
          {hasAccounts
            ? t("Open a new terminal window to start using gitch.")
            : t("Start with Add account. You can complete SSH setup here, then optionally enable the terminal command.")}
        </span>
      </div>
      {wizard && <GitchAccountSetup key={wizard.account?.id ?? "new"} account={wizard.account} accounts={info.accounts} onSaved={() => void load()} onClose={() => setWizard(null)} />}
      {diagnosis && <div className="form-section" style={{ gap: 8 }} role="status"><strong>{t("Setup diagnosis")}</strong>{diagnosis.checks.map((c, i) => <div key={i} className="col" style={{ gap: 2 }}><span style={{ color: c.level === "FAIL" ? "var(--red)" : c.level === "WARN" ? "var(--orange)" : "var(--text)" }}>{c.level} · {c.section}</span><span className="hint selectable">{c.message}</span></div>)}</div>}
      </>}
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="row" style={{ gap: 10 }}>
      <span className="muted" style={{ width: 130, flex: "none" }}>
        {label}
      </span>
      <span className="mono ellipsis selectable grow" style={{ fontSize: 11.5 }}>
        {children}
      </span>
    </div>
  );
}

/** macOS: CLISettings.swift presents the same examples without running them. */
function CLIWorkflowGuide() {
  const [copied, setCopied] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const commands = [
    "gitch workspace create product ../api ../web",
    "gitch workspace status product --json",
    "gitch work start feature-name --workspace product",
    "gitch work info feature-name --json",
    "gitch work commit --work feature-name -m \"Area: Describe change\"",
    "gitch work push --work feature-name",
    "gitch work pr --work feature-name --title \"Describe change\" --body-file pr.md",
    "gitch work end feature-name",
    "gitch issue list --json",
    "gitch issue show 123 --json",
    "gitch pr list --json",
  ];
  const copy = async (command: string) => {
    setCopied(null);
    setError(null);
    try {
      await navigator.clipboard.writeText(command);
      setCopied(command);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };
  return <details className="form-section" data-cli-workflow-guide style={{ padding: 12 }}>
    <summary style={{ cursor: "pointer", fontWeight: 600 }}>{t("Multi-repository CLI workflows")}</summary>
    <div className="col" style={{ gap: 10, paddingTop: 10 }}>
      <span className="hint">{t("Group local repositories and manage one task across them. Replace the example paths, names and issue number before running a command.")}</span>
      {commands.map((command) => <div className="row" key={command} style={{ alignItems: "flex-start", gap: 8 }}>
        <code className="selectable grow" style={{ fontSize: 11.5, whiteSpace: "pre-wrap", overflowWrap: "anywhere", minWidth: 0 }}>{command}</code>
        <Button size="small" tip={t("Copy command")} aria-label={t("Copy command")} onClick={() => void copy(command)}><Copy size={13} /></Button>
      </div>)}
      <span className="hint">{t("Commit uses staged files. End returns to the recorded branch, keeps task branches, and stops if changes or an unexpected branch need attention.")}</span>
      <span className="hint">{t("CLI repository groups are stored locally, separately from app workspaces. Use gitch workspace --help or gitch work --help for options, and gitch completion for shell suggestions.")}</span>
      {copied && <span className="hint" role="status">{t("Copied")}</span>}
      {error && <span className="error-text selectable" role="alert">{error}</span>}
    </div>
  </details>;
}
