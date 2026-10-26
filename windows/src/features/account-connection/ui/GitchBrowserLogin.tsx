import { useEffect, useRef, useState } from "react";
import { browserLoginTimeout, gitch, type GitHubLoginCapability, type GitchBrowserLogin } from "@/entities/gitch";
import { AccountConnectionFailure, accountConnectionMessage, accounts } from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";

/** 공식 CLI는 인증을, 앱은 공개 코드와 완료 상태를 소유한다. 화면 이탈/취소 뒤의 늦은 응답은 폐기한다. */
export function GitchBrowserLogin({ onConnected, expectedLogin, capability = "standard" }: { onConnected?: (login: string, email: string) => void; expectedLogin?: string; capability?: GitHubLoginCapability }) {
  const [flow, setFlow] = useState<GitchBrowserLogin | null>(null);
  const [starting, setStarting] = useState(false);
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [connected, setConnected] = useState<string | null>(null);
  const session = useRef<string | null>(null);
  const generation = useRef(0);
  const mounted = useRef(true);
  const opened = useRef<string | null>(null);
  const startedAt = useRef(0);
  const preparingAt = useRef<number | null>(null);
  const notify = useRef(onConnected); notify.current = onConnected;
  const current = (op: number) => mounted.current && generation.current === op;
  const verifyLogin = (login: string) => {
    if (expectedLogin && login.toLowerCase() !== expectedLogin.toLowerCase()) throw new AccountConnectionFailure("identity-mismatch", { expectedLogin });
  };
  useEffect(() => {
    mounted.current = true;
    setFlow(null); setStarting(false); setConnecting(false); setError(null); setConnected(null);
    return () => {
      mounted.current = false; generation.current++;
      const id = session.current; session.current = null;
      if (id) void gitch.cancelBrowserLogin(id).catch(() => {});
    };
  }, [expectedLogin, capability]);
  useEffect(() => {
    if (!flow || flow.state !== "pending") return;
    const op = generation.current;
    let latest = flow;
    let failures = 0;
    let timer: ReturnType<typeof setTimeout>;
    const stop = (message: string) => {
      if (!current(op) || session.current !== flow.session) return;
      session.current = null;
      clearTimeout(timer);
      setFlow({ ...latest, state: "failed", message }); setError(message);
      void gitch.cancelBrowserLogin(flow.session).catch(() => {});
    };
    const updatePhase = (next: GitchBrowserLogin) => {
      if (next.phase === "queued") preparingAt.current = null;
      else if (preparingAt.current === null) preparingAt.current = Date.now();
    };
    const openPage = (next: GitchBrowserLogin) => {
      if (!next.deviceCode || opened.current === next.session) return;
      opened.current = next.session;
      void ipc.openUrl(next.verificationURL).catch((e: unknown) => { if (current(op)) setError(e instanceof Error ? e.message : String(e)); });
    };
    updatePhase(flow); openPage(flow);
    const watchdog = setInterval(() => {
      const now = Date.now();
      const timeout = browserLoginTimeout(latest, now - startedAt.current, preparingAt.current === null ? 0 : now - preparingAt.current);
      if (timeout) stop(timeout === "code" ? t("GitHub didn't provide a sign-in code. Check your connection, then try again.") : t("Browser approval timed out. Start sign-in again."));
    }, 1000);
    const poll = async () => {
      try {
        const next = await gitch.browserLoginStatus(flow.session);
        if (!current(op) || session.current !== flow.session) return;
        latest = next; if (failures) setError(null); failures = 0; updatePhase(next);
        if (next.state === "complete" && next.login && next.email) {
          // 승인 이후의 비밀 저장소 연결은 별도 단계다. 이 단계에서는 취소 대신 진행 상태를 보인다.
          session.current = null; setFlow(next); setConnecting(true);
          try {
            verifyLogin(next.login);
            await accounts.importGitHubCLI(next.login);
            if (!current(op)) return;
            setConnected(next.login); setError(null);
            notify.current?.(next.login, next.email);
          } catch (e) {
            if (current(op)) setError(accountConnectionMessage(e));
          } finally { if (current(op)) setConnecting(false); }
          return;
        }
        setFlow(next);
        if (next.state === "failed" || next.state === "cancelled") {
          session.current = null; setError(next.message || t("Browser login didn't finish. Try again.")); return;
        }
        openPage(next);
      } catch (e) {
        if (!current(op) || session.current !== flow.session) return;
        const message = e instanceof Error ? e.message : String(e);
        if (++failures >= 3) { stop(t("Couldn't check browser sign-in. Start sign-in again. {0}", message)); return; }
        setError(t("Couldn't check sign-in status. Retrying… {0}", message));
      }
      if (current(op) && session.current === flow.session) timer = setTimeout(() => void poll(), 1500);
    };
    timer = setTimeout(() => void poll(), 500);
    return () => { clearTimeout(timer); clearInterval(watchdog); };
  }, [flow?.session, flow?.state]);
  const start = async () => {
    const op = ++generation.current;
    startedAt.current = Date.now(); preparingAt.current = null; opened.current = null;
    setStarting(true); setFlow(null); setError(null); setConnected(null);
    try {
      const next = await gitch.startBrowserLogin(capability, expectedLogin);
      if (!current(op)) { await gitch.cancelBrowserLogin(next.session).catch(() => {}); return; }
      session.current = next.session; setFlow(next);
    } catch (e) { if (current(op)) setError(e instanceof Error ? e.message : String(e)); }
    finally { if (current(op)) setStarting(false); }
  };
  const cancel = async () => {
    const op = ++generation.current;
    const id = session.current; session.current = null;
    setFlow(null); setStarting(false); setError(null);
    if (!id) return;
    try { await gitch.cancelBrowserLogin(id); }
    catch (e) { if (current(op)) setError(e instanceof Error ? e.message : String(e)); }
  };
  const reconnect = async () => {
    if (!flow?.login || !flow.email) return;
    const op = ++generation.current;
    setError(null); setConnecting(true);
    try {
      verifyLogin(flow.login); await accounts.importGitHubCLI(flow.login);
      if (current(op)) { setConnected(flow.login); notify.current?.(flow.login, flow.email); }
    } catch (e) { if (current(op)) setError(accountConnectionMessage(e)); }
    finally { if (current(op)) setConnecting(false); }
  };
  const pending = flow?.state === "pending";
  return <div className="form-section" style={{ gap: 8 }}>
    <strong>{capability === "projects" ? t("Connect GitHub project access") : t("Connect with your browser")}</strong>
    {capability === "projects" ? <>
      <span className="hint">{t("GitHub Projects needs the additional project permission to list projects and update their status. Review it in your browser before approving.")}</span>
      {expectedLogin && <span>{t("Approve access with the selected account: @{0}", expectedLogin)}</span>}
    </> : <>
      <span className="hint">{t("Sign in to GitHub in your default browser (Chrome if it is your default). Gitrochi then connects the account and fills in your Git username and email. You won't need to paste a token.")}</span>
      <span className="hint">{t("This uses the official GitHub CLI. GitHub will ask you to approve access for repositories, PRs, your email and SSH public-key registration.")}</span>
    </>}
    {!pending && !connecting && <div className="row"><Button kind="primary" disabled={starting || (capability === "projects" && !expectedLogin)} onClick={() => void start()}>{flow?.state === "failed" || flow?.state === "cancelled" ? t("Try sign-in again") : capability === "projects" ? t("Continue to approve project access") : t("Sign in to GitHub in browser")}</Button><Button onClick={() => void ipc.openUrl("https://cli.github.com/")}>{t("Get GitHub CLI")}</Button></div>}
    {starting && <span className="row" role="status"><Spinner />{t("Starting GitHub sign-in…")}</span>}
    {pending && <>
      <span className="row" role="status"><Spinner />{flow.deviceCode ? t("Waiting for browser approval…") : flow.phase === "queued" ? t("Waiting for another sign-in to finish…") : t("Preparing your GitHub sign-in code…")}</span>
      {!flow.deviceCode && <><span className="hint">{flow.phase === "queued" ? t("Another GitHub sign-in is still running. Finish or cancel it to continue.") : t("The one-time code will appear here before the browser opens. If it cannot be prepared, you can try again.")}</span><Button onClick={() => void ipc.openUrl(flow.verificationURL).catch((e: unknown) => setError(String(e)))}>{t("Open GitHub sign-in page")}</Button></>}
      {flow.deviceCode && <><strong className="mono selectable" style={{ fontSize: 22, letterSpacing: 2 }}>{flow.deviceCode}</strong><span className="hint">{t("Enter this one-time code on GitHub, then return here. The account connects automatically after approval.")}</span><div className="row"><Button onClick={() => void navigator.clipboard.writeText(flow.deviceCode!).catch((e) => setError(String(e)))}>{t("Copy sign-in code")}</Button><Button onClick={() => void ipc.openUrl(flow.verificationURL).catch((e) => setError(String(e)))}>{t("Open sign-in page again")}</Button></div></>}
      <Button onClick={() => void cancel()}>{t("Cancel sign-in")}</Button>
    </>}
    {connecting && <span className="row" role="status"><Spinner />{t("Connecting the approved account…")}</span>}
    {flow?.state === "complete" && !connected && !connecting && <Button onClick={() => void reconnect()}>{t("Connect authorized account")}</Button>}
    {connected && <span role="status" style={{ color: "var(--green)" }}>{t("Connected as {0}", connected)}</span>}
    {error && <><span className="error-text selectable" role="alert">{error}</span>{pending && <Button onClick={() => void cancel()}>{t("Cancel and retry")}</Button>}</>}
    {capability === "standard" && <span className="hint">{t("For a company GitLab server, use account details below. Browser OAuth there requires an application registered by your server administrator.")}</span>}
  </div>;
}
