import { useEffect, useRef, useState, type ReactNode } from "react";
import type { PullRequest } from "@/entities/git";
import {
  accounts,
  inboxPage,
  requestPage,
  type InboxItem,
  type ReviewAccess,
} from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { CollaborationInboxSheet } from "@/features/collaboration-inbox";
import { AccountWorkPanel } from "@/features/account-work";
import { CIPanel, CIRunDetail } from "@/features/ci-panel";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty, Spinner } from "@/shared/ui";
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
/** Actions: the runs on the left, the selected run with its jobs and a job's log on the right, like the Pull requests page (macOS: ActionsWorkspacePanel) */
export function ActionsWorkspacePanel({
  store,
  openSettings,
}: WorkspacePanelProps) {
  useObserve(store);
  useObserve(store.ci);
  const settingsOpener =
    openSettings ??
    (() =>
      window.dispatchEvent(
        new CustomEvent("gitrochi-open-settings", { detail: "accounts" }),
      ));
  // a CI badge may ask for a run in a repository without a remote; nothing can show it, so let go
  useEffect(() => {
    if (store.target || store.ciFocus === null) return;
    store.ciFocus = null;
    store.changed();
  }, [store, store.target, store.ciFocus]);
  if (!store.target)
    return (
      <div
        className="col grow"
        style={{ alignItems: "center", justifyContent: "center", gap: 12 }}
      >
        <Empty
          title={t("No hosting remote")}
          detail={t(
            "Open a repository with a GitHub or GitLab remote to use this workspace.",
          )}
        />
        <Button onClick={settingsOpener}>{t("Connect account…")}</Button>
      </div>
    );
  const run = store.ci.pipelines.find((p) => p.id === store.ciSelected);
  return (
    <div className="workspace-pr-page">
      <div className="workspace-pr-list col">
        <CIPanel store={store} openSettings={settingsOpener} />
      </div>
      <div className="workspace-pr-detail col">
        {run ? (
          <CIRunDetail store={store} pipeline={run} />
        ) : (
          <Empty
            title={t("Select a run")}
            detail={t("Choose a run to see its jobs and read their logs.")}
          />
        )}
      </div>
    </div>
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
