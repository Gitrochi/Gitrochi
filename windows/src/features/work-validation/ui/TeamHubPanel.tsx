import { useEffect, useRef, useState } from "react";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";
import { readTeamSnapshot, teamHubEndpoint, teamRepoKey, type TeamSnapshot } from "@/shared/lib";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";

export function TeamHubPanel({ store }: { store: RepoStore }) {
  const [endpoint, setEndpoint] = useState(settings.get("teamHubEndpoint", ""));
  const [repo, setRepo] = useState(() => { try { return teamRepoKey(store.remoteURLs.origin ?? Object.values(store.remoteURLs)[0] ?? ""); } catch { return ""; } });
  const [token, setToken] = useState("");
  const [snapshot, setSnapshot] = useState<TeamSnapshot | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [connected, setConnected] = useState(false);
  const generation = useRef(0);
  const mounted = useRef(true);
  const connection = useRef<{ endpoint: string; repo: string; token: string } | null>(null);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; generation.current++; connection.current = null; }; }, []);
  useEffect(() => { generation.current++; connection.current = null; setSnapshot(null); setConnected(false); setBusy(false); setError(""); }, [endpoint, repo, token, store.path]);
  const refresh = async () => {
    const value = connection.current; if (!value) return;
    const request = ++generation.current;
    setBusy(true);
    try {
      const result = await readTeamSnapshot(value.endpoint, value.repo, value.token);
      if (mounted.current && request === generation.current) { setSnapshot(result); setConnected(true); setError(""); }
    } catch { if (mounted.current && request === generation.current) { setConnected(false); setError(t("The team hub is disconnected. Previously observed data may be stale.")); } }
    finally { if (mounted.current && request === generation.current) setBusy(false); }
  };
  useEffect(() => { const timer = setInterval(() => { if (connection.current) void refresh(); }, 30000); return () => clearInterval(timer); }, []);
  const connect = async () => {
    const request = generation.current;
    try {
      const base = teamHubEndpoint(endpoint), key = teamRepoKey(repo);
      const secretKey = "teamHub:" + base;
      const credential = token || await ipc.secretGet(secretKey);
      if (!credential) throw new Error(t("Enter a team hub token. It is stored only in the system credential store."));
      if (token) await ipc.secretSet(secretKey, token);
      if (!mounted.current || request !== generation.current) return;
      settings.set("teamHubEndpoint", base);
      connection.current = { endpoint: base, repo: key, token: credential };
      await refresh();
    } catch (error) { setError(error instanceof Error ? t(error.message) : t("Could not connect to the team hub.")); }
  };
  return <section className="validation-section" aria-label={t("Team overlap evidence")}>
    <h3>{t("Team overlap evidence")}</h3>
    <div className="validation-fields">
      <label>{t("Hub URL")}<input className="input" aria-label={t("Hub URL")} value={endpoint} onChange={event => setEndpoint(event.target.value)} placeholder="https://hub.example.com" /></label>
      <label>{t("Repository key")}<input className="input" aria-label={t("Repository key")} value={repo} onChange={event => setRepo(event.target.value)} placeholder="example.com/team/app" /></label>
      <label>{t("Hub token")}<input className="input" aria-label={t("Hub token")} type="password" autoComplete="off" value={token} onChange={event => setToken(event.target.value)} /></label>
    </div>
    <div className="row wrap"><Button disabled={busy || !endpoint || !repo} onClick={() => void connect()}>{t("Connect and read")}</Button><Button disabled={busy || !connection.current} onClick={() => void refresh()}>{t("Refresh")}</Button>{busy && <Spinner size={14} />}<span role="status" className="hint">{t(connected ? "Connected · refreshes every 30 seconds" : "Disconnected")}</span></div>
    {snapshot && <><p className="hint">{t("Observed at {0}", snapshot.observedAt)}</p><p className="hint">{t("{0} active participants", snapshot.presence.length)}</p><div role="list">{snapshot.overlaps.map((overlap, i) => <div role="listitem" key={i} className="validation-overlap"><strong>{overlap.a.member} · {overlap.b.member}</strong> — {t(overlap.kind === "same-file" ? "Same-file observation" : "Related-file inference")}<div className="hint">{overlap.a.branch} ↔ {overlap.b.branch}</div><ul>{overlap.paths.map(path => <li className="mono" key={path}>{path}</li>)}</ul><Button disabled={!connected || !!store.graphJob} onClick={() => void store.openWorkGraphForPaths(overlap.paths)}>{t("View overlap in graph")}</Button></div>)}</div>{!snapshot.overlaps.length && <p>{t("No overlaps were reported in this snapshot.")}</p>}</>}
    {error && <p role="alert" className="error-text">{error}</p>}
    <p className="hint">{t("This view reads configured hub snapshots. It does not publish your files or start a monitor.")}</p>
  </section>;
}
