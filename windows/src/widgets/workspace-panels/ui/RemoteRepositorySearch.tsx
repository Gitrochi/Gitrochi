import { useEffect, useRef, useState } from "react";
import { accountApiBase, accountHost, type RemoteRepo } from "@/entities/git";
import { accounts, searchWorkspaceRepositories } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Spinner } from "@/shared/ui";

/** Search repositories on a connected GitHub or GitLab account and clone one; shown on the Home page (macOS: RemoteRepositorySearch.swift) */
export function RemoteRepositorySearch({ store, openSettings }: { store: RepoStore; openSettings?: () => void }) {
  useObserve(accounts);
  const [query, setQuery] = useState("");
  const [accountID, setAccountID] = useState("");
  const [items, setItems] = useState<RemoteRepo[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [page, setPage] = useState(0);
  const [more, setMore] = useState(false);
  const generation = useRef(0);
  // a changed account, query or token invalidates the list and any answer still on its way
  useEffect(() => { generation.current++; setItems([]); setPage(0); setMore(false); setBusy(false); setError(""); }, [accountID, query, accounts.revision]);
  useEffect(() => () => { generation.current++; }, []);
  const search = async (append = false) => {
    const a = accounts.accounts.find((a) => a.id === accountID);
    if (!a) return;
    const n = ++generation.current, revision = accounts.revision;
    setBusy(true);
    setError("");
    try {
      const token = await accounts.token(a);
      if (!token) throw new Error(t("No token. Reconnect the account in Settings."));
      const current = () => n === generation.current && accounts.revision === revision;
      const p = append ? page + 1 : 1;
      const result = await searchWorkspaceRepositories({ target: { provider: a.provider, host: accountHost(a), path: "", remote: "" }, token, apiBase: accountApiBase(a), me: a.username, stillCurrent: current }, query, p);
      if (current()) {
        setItems((old) => (append ? [...old, ...result.items.filter((i) => !old.some((o) => o.fullName === i.fullName))] : result.items));
        setPage(p);
        setMore(result.more);
      }
    } catch (e) {
      if (n === generation.current) setError(e instanceof Error ? e.message : String(e));
    } finally {
      if (n === generation.current) setBusy(false);
    }
  };
  const connect = openSettings ?? (() => window.dispatchEvent(new CustomEvent("gitrochi-open-settings", { detail: "accounts" })));
  return (
    <div className="remote-search">
      <div className="col" style={{ gap: 8, padding: 16 }}>
        <strong>{t("Repositories on a server")}</strong>
        {!accounts.accounts.length ? (
          <>
            <span className="hint">{t("Connect a GitHub or GitLab account to search its repositories.")}</span>
            <div className="row"><Button size="small" onClick={connect}>{t("Connect account…")}</Button></div>
          </>
        ) : (
          <>
            <select className="select" aria-label={t("Account and server")} value={accountID} onChange={(e) => setAccountID(e.target.value)}>
              <option value="">{t("Choose an account and server")}</option>
              {accounts.accounts.map((a) => <option key={a.id} value={a.id}>{accountHost(a)} · @{a.username}</option>)}
            </select>
            <div className="row">
              <input className="input grow" aria-label={t("Search remote repositories")} placeholder={t("Search remote repositories")} value={query} onChange={(e) => setQuery(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") void search(); }} />
              <Button disabled={!accountID || busy} onClick={() => void search()}>{t("Search")}</Button>
              {busy && <Spinner size={13} />}
            </div>
            <span className="hint">{t("An empty search lists repositories you belong to.")}</span>
          </>
        )}
        {error && <p role="alert" className="error-text selectable" style={{ margin: 0 }}>{error}</p>}
      </div>
      {(items.length > 0 || more) && <div className="col remote-search-results">
        {items.map((r) => (
          <div className="remote-search-row" key={r.fullName}>
            <div className="col grow" style={{ gap: 2 }}>
              <strong className="ellipsis">{r.fullName}</strong>
              <span className="hint">{r.isPrivate ? t("Private") : t("Public")}{r.summary ? ` · ${r.summary}` : ""}</span>
            </div>
            <Button size="small" onClick={() => store.openSheet({ kind: "clone", url: r.cloneURL })}>{t("Clone…")}</Button>
          </div>
        ))}
        {more && <div style={{ padding: "4px 16px 12px" }}><Button size="small" disabled={busy} onClick={() => void search(true)}>{t("Load more")}</Button></div>}
      </div>}
      {page > 0 && !items.length && !busy && <p className="muted" style={{ margin: "0 16px 12px" }}>{t("No repositories found.")}</p>}
    </div>
  );
}
