import { useEffect, useRef, useState, type ReactNode } from "react";
import {
  accountApiBase,
  accountHost,
  statusCount,
  type RemoteRepo,
  type PullRequest,
} from "@/entities/git";
import {
  accounts,
  inboxPage,
  issuePage,
  requestPage,
  saveWorkspaceIssue,
  searchWorkspaceRepositories,
  workspaceJobLog,
  type InboxItem,
  type IssueScope,
  type ReviewAccess,
} from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { workspace } from "@/entities/workspace";
import { gitch, type GitchDoctor } from "@/entities/gitch";
import { CollaborationInboxSheet } from "@/features/collaboration-inbox";
import { AccountWorkPanel } from "@/features/account-work";
import { CIPanel } from "@/features/ci-panel";
import { GitchGuide } from "@/features/gitch-guide";
import { basename, recents, samePath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Spinner } from "@/shared/ui";
import "./workspace-panels.css";

export interface WorkspacePanelProps {
  store: RepoStore;
  openSettings?: () => void;
}
const message = (e: unknown) => (e instanceof Error ? e.message : String(e));
function Page({
  title,
  subtitle,
  children,
  actions,
}: {
  title: string;
  subtitle?: string;
  children: ReactNode;
  actions?: ReactNode;
}) {
  return (
    <section className="workspace-page">
      <header>
        <div>
          <h1>{t(title)}</h1>
          {subtitle && <p className="muted">{subtitle}</p>}
        </div>
        <div className="row">{actions}</div>
      </header>
      {children}
    </section>
  );
}
async function access(store: RepoStore): Promise<ReviewAccess> {
  const c = await store.workspaceAccess();
  if (!c) throw new Error(t("Connect an account to load this workspace."));
  return c;
}
const identity = (store: RepoStore) =>
  `${store.path}|${store.collaborationRevision}|${store.target?.host}/${store.target?.path}|${store.hostingAccount?.id}|${accounts.revision}`;
function AccountNeeded({ store, openSettings }: WorkspacePanelProps) {
  if (store.target && store.hostingAccount) return null;
  if (!store.target)
    return (
      <div className="workspace-card">
        <p>
          {t(
            "Open a repository with a GitHub or GitLab remote to use this workspace.",
          )}
        </p>
        <Button onClick={() => void store.pickAndOpen()}>
          {t("Open repository…")}
        </Button>
      </div>
    );
  return (
    <div className="workspace-card">
      <p>{t("Connect an account to load this workspace.")}</p>
      <Button
        onClick={
          openSettings ??
          (() =>
            window.dispatchEvent(
              new CustomEvent("gitrochi-open-settings", { detail: "accounts" }),
            ))
        }
      >
        {t("Connect account…")}
      </Button>
    </div>
  );
}
export function WorkspaceHomePanel({ store }: WorkspacePanelProps) {
  useObserve(store);
  useObserve(workspace);
  const opened = workspace.tabs.filter((s) => s.path);
  return (
    <Page
      title="Home"
      subtitle={t("Your repositories and the next useful steps.")}
      actions={
        <>
          <Button onClick={() => void store.pickAndOpen()}>
            {t("Open repository…")}
          </Button>
          <Button onClick={() => store.openSheet({ kind: "clone" })}>
            {t("Clone repository…")}
          </Button>
          <Button onClick={() => void store.pickAndInit()}>
            {t("Create new repository…")}
          </Button>
          <Button
            onClick={() =>
              window.dispatchEvent(
                new CustomEvent("gitrochi-open-settings", { detail: "cli" }),
              )
            }
          >
            {t("Get started with Git accounts…")}
          </Button>
        </>
      }
    >
      {store.path && (
        <div className="workspace-card">
          <h2>{store.name}</h2>
          <p className="mono muted">{store.path}</p>
          <div className="workspace-metrics">
            <span>{store.headBranch ?? t("Detached HEAD")}</span>
            <span>{t("{0} modified files", statusCount(store.status))}</span>
            <span>
              ↑{store.status.ahead} ↓{store.status.behind}
            </span>
            <span>
              {store.gitchStatus?.account ?? t("Account not checked")}
            </span>
          </div>
          <div className="row">
            <Button onClick={() => store.navigate("changes")}>
              {t("Review changes")}
            </Button>
            <Button disabled={!!store.busy} onClick={() => void store.reload()}>
              {t("Refresh")}
            </Button>
          </div>
        </div>
      )}
      <h2>{t("Open repositories")}</h2>
      <div className="workspace-grid">
        {opened.map((s) => (
          <div className="workspace-card" key={s.id}>
            <strong>{s.name}</strong>
            <p className="muted mono">{s.path}</p>
            <span>
              {s.headBranch} · ↑{s.status.ahead} ↓{s.status.behind}
            </span>
            <Button onClick={() => workspace.select(s.id)}>
              {t("Open repository")}
            </Button>
          </div>
        ))}
      </div>
      <h2>{t("Recent local repositories")}</h2>
      {recents()
        .filter((p) => !opened.some((s) => samePath(s.path, p)))
        .slice(0, 8)
        .map((p) => (
          <div key={p} className="workspace-list-row">
            <div>
              <strong>{basename(p)}</strong>
              <p className="muted mono">{p}</p>
            </div>
            <Button onClick={() => void workspace.openInNewTab(p)}>
              {t("Open repository")}
            </Button>
          </div>
        ))}
      {!store.path && !opened.length && (
        <p className="muted">
          {t("Open a local repository or clone one to get started.")}
        </p>
      )}
    </Page>
  );
}
export function RepositoryLibraryPanel({
  store,
  openSettings,
}: WorkspacePanelProps) {
  useObserve(workspace);
  useObserve(accounts);
  const [query, setQuery] = useState("");
  const [accountID, setAccountID] = useState("");
  const [items, setItems] = useState<RemoteRepo[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [page, setPage] = useState(0);
  const [more, setMore] = useState(false);
  const generation = useRef(0);
  useEffect(() => {
    generation.current++;
    setItems([]);
    setPage(0);
    setMore(false);
    setBusy(false);
    setError("");
  }, [accountID, query, accounts.revision]);
  useEffect(
    () => () => {
      generation.current++;
    },
    [],
  );
  const search = async (append = false) => {
    const a = accounts.accounts.find((a) => a.id === accountID);
    if (!a) return;
    const n = ++generation.current,
      revision = accounts.revision;
    setBusy(true);
    setError("");
    try {
      const token = await accounts.token(a);
      if (!token)
        throw new Error(t("No token. Reconnect the account in Settings."));
      const current = () =>
        n === generation.current && accounts.revision === revision;
      const p = append ? page + 1 : 1;
      const result = await searchWorkspaceRepositories(
        {
          target: {
            provider: a.provider,
            host: accountHost(a),
            path: "",
            remote: "",
          },
          token,
          apiBase: accountApiBase(a),
          me: a.username,
          stillCurrent: current,
        },
        query,
        p,
      );
      if (current()) {
        setItems((old) =>
          append
            ? [
                ...old,
                ...result.items.filter(
                  (i) => !old.some((o) => o.fullName === i.fullName),
                ),
              ]
            : result.items,
        );
        setPage(p);
        setMore(result.more);
      }
    } catch (e) {
      if (n === generation.current) setError(message(e));
    } finally {
      if (n === generation.current) setBusy(false);
    }
  };
  const opened = workspace.tabs.filter((s) => s.path),
    recent = recents().filter((p) => !opened.some((s) => samePath(s.path, p)));
  return (
    <Page
      title="Repositories"
      subtitle={t("Local folders stay separate from repositories on a server.")}
      actions={
        <>
          <Button onClick={() => void store.pickAndOpen()}>
            {t("Open repository…")}
          </Button>
          <Button onClick={() => store.openSheet({ kind: "clone" })}>
            {t("Clone repository…")}
          </Button>
        </>
      }
    >
      <h2>{t("Open local repositories")}</h2>
      {opened.map((s) => (
        <div className="workspace-list-row" key={s.id}>
          <div>
            <strong>{s.name}</strong>
            <p className="mono muted">{s.path}</p>
          </div>
          <Button onClick={() => workspace.select(s.id)}>
            {t("Open repository")}
          </Button>
        </div>
      ))}
      <h2>{t("Recent local repositories")}</h2>
      {recent.map((p) => (
        <div className="workspace-list-row" key={p}>
          <div>
            <strong>{basename(p)}</strong>
            <p className="mono muted">{p}</p>
          </div>
          <Button onClick={() => void workspace.openInNewTab(p)}>
            {t("Open repository")}
          </Button>
        </div>
      ))}
      <h2>{t("Repositories on a server")}</h2>
      <p className="muted">
        {t(
          "Choose an account and server, then search. An empty search lists repositories you belong to.",
        )}
      </p>
      <div className="row">
        <select
          aria-label={t("Account and server")}
          value={accountID}
          onChange={(e) => setAccountID(e.target.value)}
        >
          <option value="">{t("Choose an account and server")}</option>
          {accounts.accounts.map((a) => (
            <option key={a.id} value={a.id}>
              {accountHost(a)} · @{a.username}
            </option>
          ))}
        </select>
        <input
          className="input grow"
          aria-label={t("Search remote repositories")}
          placeholder={t("Search remote repositories")}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") void search();
          }}
        />
        <Button disabled={!accountID || busy} onClick={() => void search()}>
          {t("Search")}
        </Button>
        {busy && <Spinner />}
      </div>
      {!accounts.accounts.length && (
        <Button onClick={openSettings}>{t("Connect account…")}</Button>
      )}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      {items.map((r) => (
        <div className="workspace-list-row" key={r.fullName}>
          <div>
            <strong>{r.fullName}</strong>
            <p className="muted">
              {r.isPrivate ? t("Private") : t("Public")} · {r.summary}
            </p>
          </div>
          <Button
            onClick={() => store.openSheet({ kind: "clone", url: r.cloneURL })}
          >
            {t("Clone…")}
          </Button>
        </div>
      ))}
      {more && (
        <Button disabled={busy} onClick={() => void search(true)}>
          {t("Load more")}
        </Button>
      )}
      {page > 0 && !items.length && !busy && (
        <p className="muted">{t("No repositories found.")}</p>
      )}
    </Page>
  );
}
function RepositoryWorkInboxPanel(props: WorkspacePanelProps) {
  useObserve(props.store);
  return (
    <Page title="Inbox">
      <AccountNeeded {...props} />
      {props.store.target && (
        <CollaborationInboxSheet
          store={props.store}
          close={() => {}}
          embedded
          initialKind="mention"
        />
      )}
    </Page>
  );
}
function RepositoryMyWorkPanel(props: WorkspacePanelProps) {
  const { store } = props;
  useObserve(store);
  useObserve(accounts);
  const key = identity(store);
  const [state, setState] = useState<{
    mine: PullRequest[];
    reviews: InboxItem[];
    issues: InboxItem[];
    more: boolean;
    busy: boolean;
    error: string;
  }>({
    mine: [],
    reviews: [],
    issues: [],
    more: false,
    busy: false,
    error: "",
  });
  const gen = useRef(0);
  const load = async () => {
    if (!store.target || !store.hostingAccount) {
      setState({
        mine: [],
        reviews: [],
        issues: [],
        more: false,
        busy: false,
        error: "",
      });
      return;
    }
    const n = ++gen.current;
    setState({
      mine: [],
      reviews: [],
      issues: [],
      more: false,
      busy: true,
      error: "",
    });
    try {
      const c = await access(store);
      const [mine, reviews, issues] = await Promise.all([
        requestPage(c, { scope: "mine", search: "", page: 1 }),
        inboxPage(c, "review"),
        inboxPage(c, "issue"),
      ]);
      if (n === gen.current && c.stillCurrent?.())
        setState({
          mine: mine.items,
          reviews: reviews.items,
          issues: issues.items,
          more: mine.more || reviews.more || issues.more,
          busy: false,
          error: "",
        });
    } catch (e) {
      if (n === gen.current)
        setState((s) => ({ ...s, busy: false, error: message(e) }));
    }
  };
  useEffect(() => {
    void load();
    return () => {
      gen.current++;
    };
  }, [key]);
  return (
    <Page
      title="My work"
      subtitle={
        store.target
          ? `${store.target.host}/${store.target.path} · @${store.hostingAccount?.username ?? ""}`
          : undefined
      }
      actions={
        <Button disabled={state.busy} onClick={() => void load()}>
          {t("Refresh")}
        </Button>
      }
    >
      <AccountNeeded {...props} />
      {state.busy && <Spinner />}
      {state.error && (
        <p role="alert" className="error-text">
          {state.error}
        </p>
      )}
      {[
        ["My pull requests", state.mine],
        ["Review requested", state.reviews],
        ["Assigned issues", state.issues],
      ].map(([title, list]) => (
        <div className="workspace-card" key={title as string}>
          <h2>{t(title as string)}</h2>
          {(list as { number: number; title: string; url: string }[]).map(
            (i) => (
              <div className="workspace-list-row" key={i.number}>
                <span>
                  #{i.number} {i.title}
                </span>
                <Button size="small" onClick={() => store.openUrl(i.url)}>
                  {t("Browser")}
                </Button>
              </div>
            ),
          )}
          {!(list as unknown[]).length && !state.busy && (
            <p className="muted">{t("No items in this page.")}</p>
          )}
        </div>
      ))}
      {state.more && (
        <p className="muted">
          {t(
            "This overview shows the first page. Open Pull requests or Issues to search and load more.",
          )}
        </p>
      )}
    </Page>
  );
}
export function IssuesWorkspacePanel(props: WorkspacePanelProps) {
  const { store } = props;
  useObserve(store);
  useObserve(accounts);
  const key = identity(store);
  const [scope, setScope] = useState<IssueScope>("open"),
    [query, setQuery] = useState("");
  const [items, setItems] = useState<InboxItem[]>([]),
    [page, setPage] = useState(0),
    [more, setMore] = useState(false),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const [editor, setEditor] = useState<{
    number?: number;
    title: string;
    body: string;
    origin: string;
  } | null>(null);
  const [comment, setComment] = useState("");
  const gen = useRef(0),
    mutation = useRef(false);
  const detail = store.inboxDetail;
  const load = async (append = false) => {
    if (!store.target || !store.hostingAccount) return;
    const n = ++gen.current;
    setBusy(true);
    setError("");
    try {
      const c = await access(store),
        p = append ? page + 1 : 1;
      const result = await issuePage(c, scope, query, p);
      if (n === gen.current && c.stillCurrent?.()) {
        setItems((old) =>
          append
            ? [
                ...old,
                ...result.items.filter((i) => !old.some((o) => o.id === i.id)),
              ]
            : result.items,
        );
        setPage(p);
        setMore(result.more);
      }
    } catch (e) {
      if (n === gen.current) setError(message(e));
    } finally {
      if (n === gen.current) setBusy(false);
    }
  };
  useEffect(() => {
    setEditor(null);
    setItems([]);
    setPage(0);
    setMore(false);
    store.inboxDetail = null;
    store.changed();
    void load();
    return () => {
      gen.current++;
    };
  }, [key, scope]);
  useEffect(() => setComment(""), [detail?.item.id]);
  const save = async () => {
    if (!editor || mutation.current || editor.origin !== identity(store))
      return;
    mutation.current = true;
    const draft = editor,
      identityKey = key;
    setBusy(true);
    setError("");
    try {
      const c = await access(store),
        item = await saveWorkspaceIssue(
          c,
          draft.title,
          draft.body,
          draft.number,
        );
      if (c.stillCurrent?.() && identity(store) === identityKey) {
        setEditor((current) => (current === draft ? null : current));
        await load();
        await store.openInboxItem(item);
      }
    } catch (e) {
      if (identity(store) === identityKey) setError(message(e));
    } finally {
      mutation.current = false;
      if (identity(store) === identityKey) setBusy(false);
    }
  };
  return (
    <Page
      title="Issues"
      subtitle={
        store.target ? `${store.target.host}/${store.target.path}` : undefined
      }
      actions={
        <Button
          disabled={!store.hostingAccount || busy}
          onClick={() => setEditor({ title: "", body: "", origin: key })}
        >
          {t("New issue")}
        </Button>
      }
    >
      <AccountNeeded {...props} />
      <div className="row">
        <select
          aria-label={t("Issue state")}
          disabled={busy}
          value={scope}
          onChange={(e) => setScope(e.target.value as IssueScope)}
        >
          <option value="open">{t("Open")}</option>
          <option value="closed">{t("Closed")}</option>
          <option value="all">{t("All")}</option>
        </select>
        <input
          className="input grow"
          placeholder={t("Search issues")}
          aria-label={t("Search issues")}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") void load();
          }}
        />
        <Button disabled={busy} onClick={() => void load()}>
          {t("Search")}
        </Button>
        {busy && <Spinner />}
      </div>
      {(error || store.inboxError) && (
        <p role="alert" className="error-text">
          {error || store.inboxError}
        </p>
      )}
      {editor && (
        <div className="workspace-card">
          <h2>{t(editor.number ? "Edit issue" : "New issue")}</h2>
          <label>
            {t("Title")}
            <input
              className="input"
              value={editor.title}
              disabled={busy}
              onChange={(e) => setEditor({ ...editor, title: e.target.value })}
            />
          </label>
          <label>
            {t("Description")}
            <textarea
              rows={6}
              value={editor.body}
              disabled={busy}
              onChange={(e) => setEditor({ ...editor, body: e.target.value })}
            />
          </label>
          <div className="row">
            <Button disabled={busy} onClick={() => setEditor(null)}>
              {t("Cancel")}
            </Button>
            <Button
              kind="primary"
              disabled={busy || !editor.title.trim()}
              onClick={() => void save()}
            >
              {t("Save")}
            </Button>
          </div>
        </div>
      )}
      <div className="workspace-split">
        <div>
          {items.map((i) => (
            <button
              className={`workspace-issue ${detail?.item.id === i.id ? "selected" : ""}`}
              key={i.id}
              onClick={() => void store.openInboxItem(i)}
            >
              <strong>
                #{i.number} {i.title}
              </strong>
              <span className="muted">
                {i.state} · @{i.author}
              </span>
            </button>
          ))}
          {more && (
            <Button disabled={busy} onClick={() => void load(true)}>
              {t("Load more")}
            </Button>
          )}
          {!items.length && !busy && (
            <p className="muted">{t("No items in this page.")}</p>
          )}
        </div>
        <div className="workspace-card">
          {detail?.item.kind === "issue" ? (
            <>
              <h2>
                #{detail.item.number} {detail.item.title}
              </h2>
              <div className="row">
                <span>{detail.item.state}</span>
                <Button
                  size="small"
                  disabled={busy || store.inboxBusy}
                  onClick={() =>
                    setEditor({
                      number: detail.item.number,
                      title: detail.item.title,
                      body: detail.item.body,
                      origin: key,
                    })
                  }
                >
                  {t("Edit issue")}
                </Button>
                <Button
                  size="small"
                  disabled={busy || store.inboxBusy}
                  onClick={() => store.confirmInboxState(detail.item)}
                >
                  {["open", "opened"].includes(detail.item.state)
                    ? t("Close issue…")
                    : t("Reopen…")}
                </Button>
                <Button
                  size="small"
                  onClick={() => store.openUrl(detail.item.url)}
                >
                  {t("Browser")}
                </Button>
              </div>
              <p className="selectable workspace-prose">
                {detail.item.body || t("No description")}
              </p>
              {detail.comments.map((c) => (
                <div key={c.id} className="workspace-comment">
                  <strong>@{c.author}</strong>
                  <p className="selectable workspace-prose">{c.body}</p>
                </div>
              ))}
              {detail.more && (
                <Button
                  disabled={store.inboxLoading || store.inboxBusy}
                  onClick={() => void store.openInboxItem(detail.item, true)}
                >
                  {t("Load more comments")}
                </Button>
              )}
              <textarea
                aria-label={t("Comment")}
                rows={4}
                value={comment}
                onChange={(e) => setComment(e.target.value)}
                disabled={store.inboxBusy}
              />
              <Button
                disabled={
                  !comment.trim() || store.inboxBusy || store.inboxLoading
                }
                onClick={() => {
                  const sent = comment,
                    id = detail.item.id;
                  void store
                    .inboxAction(detail.item, "comment", sent)
                    .then((ok) => {
                      if (ok && store.inboxDetail?.item.id === id)
                        setComment((c) => (c === sent ? "" : c));
                    });
                }}
              >
                {t("Comment")}
              </Button>
            </>
          ) : (
            <p className="muted">
              {t("Select an item to read its conversation.")}
            </p>
          )}
        </div>
      </div>
    </Page>
  );
}
function JobLogPanel({ store }: WorkspacePanelProps) {
  useObserve(store);
  useObserve(store.ci);
  useObserve(accounts);
  const [job, setJob] = useState(0),
    [body, setBody] = useState(""),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [truncated, setTruncated] = useState(false);
  const generation = useRef(0),
    key = identity(store);
  const jobs = [
    ...new Map(
      [...store.ci.jobs.values()].flat().map((j) => [j.id, j]),
    ).values(),
  ];
  useEffect(() => {
    generation.current++;
    setJob(0);
    setBody("");
    setError("");
    setBusy(false);
    setTruncated(false);
    return () => {
      generation.current++;
    };
  }, [key]);
  const load = async () => {
    const id = ++generation.current;
    setBusy(true);
    setError("");
    setBody("");
    try {
      const c = await access(store),
        result = await workspaceJobLog(c, job);
      if (generation.current === id && c.stillCurrent?.()) {
        setBody(result.body);
        setTruncated(result.truncated);
      }
    } catch (e) {
      if (generation.current === id) setError(message(e));
    } finally {
      if (generation.current === id) setBusy(false);
    }
  };
  return (
    <div className="workspace-card">
      <h2>{t("Job log")}</h2>
      <p className="muted">
        {t(
          "Expand a run above to load its jobs, then choose a job. Logs stay on this device.",
        )}
      </p>
      <div className="row">
        <select
          aria-label={t("Job")}
          value={job}
          onChange={(e) => {
            generation.current++;
            setJob(Number(e.target.value));
            setBody("");
            setError("");
            setBusy(false);
            setTruncated(false);
          }}
        >
          <option value={0}>{t("Choose a job")}</option>
          {jobs.map((j) => (
            <option key={j.id} value={j.id}>
              {j.name} · #{j.id}
            </option>
          ))}
        </select>
        <Button disabled={!job || busy} onClick={() => void load()}>
          {t("Load log")}
        </Button>
        {busy && <Spinner />}
        <Button disabled={!body} onClick={() => store.copy(body)}>
          {t("Copy redacted log")}
        </Button>
        {jobs.find((j) => j.id === job) && (
          <Button
            onClick={() => store.openUrl(jobs.find((j) => j.id === job)!.url)}
          >
            {t("Browser")}
          </Button>
        )}
      </div>
      {error && (
        <p className="error-text" role="alert">
          {error}
        </p>
      )}
      {truncated && (
        <p className="muted">
          {t(
            "Log preview is limited to 2 MB. Open the browser for the complete log.",
          )}
        </p>
      )}
      {body && (
        <pre
          className="selectable mono"
          style={{
            whiteSpace: "pre-wrap",
            overflowWrap: "anywhere",
            maxHeight: 440,
            overflow: "auto",
            fontSize: 12,
          }}
        >
          {body}
        </pre>
      )}
    </div>
  );
}
export function ActionsWorkspacePanel({
  store,
  openSettings,
}: WorkspacePanelProps) {
  return (
    <Page
      title={store.target?.provider === "gitlab" ? "Pipelines" : "Actions"}
      subtitle={
        store.target ? `${store.target.host}/${store.target.path}` : undefined
      }
    >
      <div className="workspace-ci">
        <CIPanel
          store={store}
          openSettings={
            openSettings ??
            (() =>
              window.dispatchEvent(
                new CustomEvent("gitrochi-open-settings", {
                  detail: "accounts",
                }),
              ))
          }
        />
      </div>
      <JobLogPanel store={store} />
    </Page>
  );
}
export function OperationsWorkspacePanel({
  store,
  openSettings,
}: WorkspacePanelProps) {
  const [doctor, setDoctor] = useState<GitchDoctor | null>(null),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  return (
    <Page
      title="Tools"
      subtitle={t(
        "Run diagnostics, explore code and find commands without opening Settings.",
      )}
    >
      <div className="workspace-card row" style={{ flexWrap: "wrap" }}>
        <Button disabled={!store.path} onClick={() => store.openSheet({ kind: "localWorkflows" })}>{t("Recovery, LFS, submodules and bisect…")}</Button>
        <Button disabled={!store.path} onClick={() => store.openSheet({ kind: "mcpConnection" })}>{t("Connect external AI with MCP…")}</Button>
      </div>
      <div className="workspace-card">
        <h2>{t("Setup diagnosis")}</h2>
        <Button
          disabled={busy}
          onClick={() => {
            setBusy(true);
            setError("");
            void gitch
              .doctor()
              .then(setDoctor, (e) => setError(message(e)))
              .finally(() => setBusy(false));
          }}
        >
          {t("Check setup")}
        </Button>
        {busy && <Spinner />}
        {error && <p className="error-text">{error}</p>}
        {doctor?.checks.map((c, i) => (
          <p key={i}>
            <strong>
              {c.level} · {c.section}
            </strong>
            <br />
            {c.message}
          </p>
        ))}
      </div>
      <GitchGuide
        onDoctor={() => {
          setBusy(true);
          void gitch
            .doctor()
            .then(setDoctor, (e) => setError(message(e)))
            .finally(() => setBusy(false));
        }}
        onAddAccount={
          openSettings ??
          (() =>
            window.dispatchEvent(
              new CustomEvent("gitrochi-open-settings", { detail: "cli" }),
            ))
        }
      />
      <span className="muted">{store.path}</span>
    </Page>
  );
}

function ScopedWorkPanel({
  store,
  openSettings,
  inbox = false,
}: WorkspacePanelProps & { inbox?: boolean }) {
  useObserve(store);
  const [scope, setScope] = useState("repository");
  const effective = store.target ? scope : "account";
  return (
    <div className="col" style={{ flex: 1, minHeight: 0 }}>
      <div className="row" style={{ padding: "16px 28px 0" }}>
        <label>
          {t("Work scope")}{" "}
          <select
            aria-label={t("Work scope")}
            value={effective}
            onChange={(e) => setScope(e.target.value)}
          >
            <option value="repository" disabled={!store.target}>
              {t("Current repository")}
            </option>
            <option value="account">
              {t("Selected account · all repositories")}
            </option>
          </select>
        </label>
      </div>
      {effective === "account" ? (
        <Page title={inbox ? "Inbox" : "My work"}>
          <AccountWorkPanel inbox={inbox} />
        </Page>
      ) : inbox ? (
        <RepositoryWorkInboxPanel store={store} openSettings={openSettings} />
      ) : (
        <RepositoryMyWorkPanel store={store} openSettings={openSettings} />
      )}
    </div>
  );
}
export function WorkInboxPanel(props: WorkspacePanelProps) {
  return <ScopedWorkPanel {...props} inbox />;
}
export function MyWorkPanel(props: WorkspacePanelProps) {
  return <ScopedWorkPanel {...props} />;
}
