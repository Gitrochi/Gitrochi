import { useEffect, useRef, useState, type ReactNode } from "react";
import type { PullRequest } from "@/entities/git";
import {
  accounts,
  inboxPage,
  requestPage,
  workspaceJobLog,
  type InboxItem,
  type ReviewAccess,
} from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { CollaborationInboxSheet } from "@/features/collaboration-inbox";
import { AccountWorkPanel } from "@/features/account-work";
import { CIPanel } from "@/features/ci-panel";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Spinner } from "@/shared/ui";
import "./workspace-panels.css";

export interface WorkspacePanelProps {
  store: RepoStore;
  openSettings?: () => void;
}
const message = (e: unknown) => (e instanceof Error ? e.message : String(e));
/** A full-width page; like Pull requests and Issues it has no large title, only its actions on top */
function Page({ children, actions }: { children: ReactNode; actions?: ReactNode }) {
  return (
    <section className="workspace-page">
      {actions && <div className="workspace-page-actions">{actions}</div>}
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
function RepositoryWorkInboxPanel(props: WorkspacePanelProps) {
  useObserve(props.store);
  return (
    <Page>
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
    <Page>
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
        <Page>
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
