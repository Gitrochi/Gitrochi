import { Globe, Lock } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { accountApiBase, accountHost, type RemoteRepo } from "@/entities/git";
import * as Hosting from "@/entities/hosting";
import { accounts } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { displayPath, env, isWindows, joinPath, slash } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Frame, Row, Spinner } from "@/shared/ui";

/** https://host/a/b.git, git@host:a/b.git → "b" */
function guessName(url: string) {
  const last = url.trim().split(/[/:]/).pop() ?? "";
  return last.endsWith(".git") ? last.slice(0, -4) : last;
}

export function CloneSheet({ store, close, initialURL = "" }: { store: RepoStore; close: () => void; initialURL?: string }) {
  useObserve(accounts);
  const [accountID, setAccountID] = useState<string | null>(accounts.accounts[0]?.id ?? null);
  const [repos, setRepos] = useState<RemoteRepo[]>([]);
  const [reposError, setReposError] = useState<string | null>(null);
  const [loadingRepos, setLoadingRepos] = useState(false);
  const [query, setQuery] = useState("");
  const [remote, setRemote] = useState(initialURL);
  const [parent, setParent] = useState(isWindows() ? joinPath(env.home, "source", "repos") : joinPath(env.home, "Desktop"));
  const [folder, setFolder] = useState(guessName(initialURL));
  const [folderEdited, setFolderEdited] = useState(false);

  useEffect(() => {
    const a = accounts.accounts.find((x) => x.id === accountID);
    if (!a) return;
    let cancelled = false;
    setLoadingRepos(true);
    setReposError(null);
    void (async () => {
      try {
        const token = await accounts.token(a);
        if (!token) throw new Error(t("No token. Reconnect the account in Settings."));
        const list = await Hosting.repositories(a.provider, token, accountApiBase(a));
        if (!cancelled) setRepos(list);
      } catch (e) {
        if (!cancelled) {
          setRepos([]);
          setReposError(e instanceof Error ? e.message : String(e));
        }
      }
      if (!cancelled) setLoadingRepos(false);
    })();
    return () => {
      cancelled = true;
    };
  }, [accountID]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    return q ? repos.filter((r) => r.fullName.toLowerCase().includes(q)) : repos;
  }, [repos, query]);

  const setURL = (v: string) => {
    setRemote(v);
    if (!folderEdited) setFolder(guessName(v));
  };

  return (
    <Frame
      title={t("Clone repository")}
      confirm={t("Clone")}
      width={600}
      canConfirm={!!remote.trim() && !!folder.trim()}
      close={close}
      onConfirm={() => void (async () => {
        await ipc.mkdirs(parent).catch(() => {});
        await store.clone(remote.trim(), parent, folder.trim());
      })()}
    >
      {accounts.accounts.length > 0 && (
        <div className="form-section">
          <div className="row">
            <span className="form-section-title grow">{t("My repositories")}</span>
            <select className="select" style={{ width: 260 }} value={accountID ?? ""} onChange={(e) => setAccountID(e.target.value)}>
              {accounts.accounts.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.provider === "github" ? "GitHub" : accountHost(a)} · @{a.username}
                </option>
              ))}
            </select>
          </div>
          <input className="input" placeholder={t("Search")} value={query} onChange={(e) => setQuery(e.target.value)} />
          <div style={{ height: 180, overflow: "auto", border: "1px solid var(--border)", borderRadius: 6, background: "var(--input)" }}>
            {loadingRepos ? (
              <div className="empty">
                <Spinner />
              </div>
            ) : reposError ? (
              <div className="error-text" style={{ padding: 10 }}>
                {reposError}
              </div>
            ) : (
              filtered.map((r) => (
                <div
                  key={r.fullName}
                  className="file-row"
                  style={{ background: r.cloneURL === remote ? "var(--select)" : undefined, alignItems: "flex-start" }}
                  onClick={() => setURL(r.cloneURL)}
                >
                  <span className="muted" style={{ marginTop: 2 }}>
                    {r.isPrivate ? <Lock size={12} /> : <Globe size={12} />}
                  </span>
                  <span className="col grow">
                    <span className="ellipsis">{r.fullName}</span>
                    {r.summary && (
                      <span className="muted ellipsis" style={{ fontSize: 11.5 }}>
                        {r.summary}
                      </span>
                    )}
                  </span>
                </div>
              ))
            )}
          </div>
        </div>
      )}
      <Row label="URL">
        <input className="input" autoFocus value={remote} placeholder={t("https://github.com/user/repo.git")} onChange={(e) => setURL(e.target.value)} spellCheck={false} />
      </Row>
      <Row label={t("Location")}>
        <span className="ellipsis grow">{displayPath(parent)}</span>
        <Button
          size="small"
          onClick={() =>
            void ipc.pickFolder(t("Clone into"), parent).then((p) => {
              if (p) setParent(slash(p));
            })
          }
        >
          {t("Change…")}</Button>
      </Row>
      <Row label={t("Folder name")}>
        <input
          className="input"
          value={folder}
          onChange={(e) => {
            setFolder(e.target.value);
            setFolderEdited(true);
          }}
          spellCheck={false}
        />
      </Row>
    </Frame>
  );
}
