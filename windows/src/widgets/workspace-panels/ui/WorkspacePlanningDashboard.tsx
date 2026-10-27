import { useEffect, useState } from "react";
import {
  RefreshCw,
  Search,
  Sun,
  Users,
} from "lucide-react";
import { accountApiBase, accountHost } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import {
  accounts,
  localHubAccess,
  hubError,
  hubProjectTarget,
  localScheduleToday,
  portfolioTasks,
  ProjectPortfolioState,
  readProjectScheduleSettings,
  readProjectPortfolioSelection,
  saveProjectPortfolioSelection,
  scheduleAddDays,
  scheduleSummary,
  type ProjectPortfolioTask,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Spinner } from "@/shared/ui";
import {
  WorkspacePlanningControls,
  WorkspacePlanningSource,
} from "./WorkspacePlanningControls";
import { WorkspacePlanningViews } from "./WorkspacePlanningViews";
import { usePlanningPortfolio } from "../model/use-planning-portfolio";
import { useProjectNavigation } from "../model/use-project-navigation";
import "./planning-dashboard.css";

/** Home reads a portfolio independently of the active project's mutable controller. */
export function WorkspacePlanningDashboard({
  store,
  fixture,
}: {
  store: RepoStore;
  fixture?: ProjectPortfolioState;
}) {
  useObserve(store);
  useObserve(accounts);
  const [owned] = useState(() => new ProjectPortfolioState()),
    data = useObserve(fixture ?? owned);
  const [accountID, setAccountID] = useState(""),
    [scope, setScope] = useState<"personal" | "repository">("personal");
  const [focus, setFocus] = useState("focus"),
    [query, setQuery] = useState(""),
    [onlyMine, setOnlyMine] = useState(false);
  const [mode, setMode] = useState("agenda"),
    [today, setToday] = useState(localScheduleToday),
    [anchor, setAnchor] = useState(localScheduleToday);
  const [, changedPreferences] = useState(0);
  const [source, setSource] = useState<"local" | "remote">(() =>
    !accounts.accounts.some((a) => a.provider === "github")
      ? "local"
      : store.hostingHub.projectSource,
  );
  const local = source === "local";
  const available = accounts.accounts.filter(
    (value) => value.provider === "github",
  );
  const account =
    available.find((value) => value.id === accountID) ??
    available.find((value) => value.id === store.hostingHub.account?.id) ??
    available[0];
  const repositoryScope =
    !!store.target &&
    !!account &&
    accounts.candidates(store.target).some((value) => value.id === account.id);
  const effectiveScope = repositoryScope ? scope : "personal";
  const selectionContext = local
    ? "local"
    : JSON.stringify([account?.id, effectiveScope, store.path, store.target]);
  const context = JSON.stringify([
    source,
    selectionContext,
    local ? 0 : accounts.revision,
  ]);
  const { readError, setReadError, isCurrent, readAccess, load, refresh } =
    usePlanningPortfolio(
      data,
      context,
      readProjectPortfolioSelection(selectionContext),
      local || !!account,
      !!fixture,
      async (stillCurrent) => {
        if (local) return localHubAccess(stillCurrent);
        if (!account)
          throw new Error(
            t("Connect a GitHub account to plan across your projects."),
          );
        const token = await accounts.token(account, {
          reportReadFailure: true,
        });
        if (!token)
          throw new Error(
            t(
              "The selected account has no token. Reconnect it from Settings → Accounts.",
            ),
          );
        return {
          target: hubProjectTarget(
            repositoryScope ? store.target : null,
            "github",
            accountHost(account),
            account.username,
            effectiveScope === "personal",
          ),
          token,
          me: account.username,
          apiBase: accountApiBase(account),
          stillCurrent,
        };
      },
    );
  useEffect(() => {
    const timer = window.setInterval(
      () => setToday(localScheduleToday()),
      60_000,
    );
    const preferences = () => changedPreferences((value) => value + 1);
    window.addEventListener("gitrochi-project-schedule-settings", preferences);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener(
        "gitrochi-project-schedule-settings",
        preferences,
      );
    };
  }, []);
  const settings = Object.fromEntries(
    data.details.map((detail) => [
      detail.item.id,
      readProjectScheduleSettings(
        local ? "local" : (account?.id ?? ""),
        detail.item.id,
      ),
    ]),
  );
  const matchesTask = (task: ProjectPortfolioTask) =>
    (!onlyMine ||
      !!task.entry.row.assignees?.some(
        (name) => name.toLowerCase() === account?.username.toLowerCase(),
      )) &&
    (!query.trim() ||
      [
        task.entry.row.title,
        task.entry.row.repository,
        ...task.projectNames,
        ...(task.entry.row.assignees ?? []),
      ]
        .join(" ")
        .toLowerCase()
        .includes(query.trim().toLowerCase()));
  const tasks = portfolioTasks(data.details, settings).filter(matchesTask);
  const summary = scheduleSummary(
      tasks.map((task) => task.entry),
      today,
    ),
    horizon = scheduleAddDays(today, 7) ?? today;
  const agenda = tasks
    .filter(({ entry }) => {
      if (focus === "completed") return entry.completed;
      if (entry.completed) return false;
      if (focus === "unscheduled") return !entry.date;
      if (focus === "overdue")
        return !entry.invalidRange && !!entry.due && entry.due < today;
      if (focus === "today") return !entry.invalidRange && entry.date === today;
      if (focus === "upcoming")
        return (
          !entry.invalidRange &&
          !!entry.date &&
          entry.date > today &&
          entry.date <= horizon
        );
      return true;
    })
    .sort(
      (left, right) =>
        (left.entry.date ?? "9999").localeCompare(right.entry.date ?? "9999") ||
        left.entry.row.title.localeCompare(right.entry.row.title),
    );
  const { opening, openProject } = useProjectNavigation(
    store,
    account,
    effectiveScope,
    isCurrent,
    context,
    source,
  );
  const chooseProject = (id: string, checked: boolean) => {
    const selected = new Set(data.selectedIDs);
    checked ? selected.add(id) : selected.delete(id);
    data.setSelected([...selected]);
    saveProjectPortfolioSelection(selectionContext, [...selected]);
    void refresh();
  };
  const metrics = [
    ["Overdue", summary.overdue, "overdue"],
    ["Today", summary.today, "today"],
    ["Next 7 days", summary.upcoming, "upcoming"],
    ["Unscheduled", summary.unscheduled, "unscheduled"],
    ["Completed", summary.completed, "completed"],
  ] as const;

  return (
    <section
      className="planning-dashboard"
      aria-label={t("Home planning dashboard")}
    >
      <header>
        <div>
          <span className="planning-eyebrow">
            <Sun size={14} />
            {t("Your planning desk")}
          </span>
          <h2>{t("A clear day starts with a clear plan.")}</h2>
          <p>
            {t("Bring project deadlines and your next actions into one place.")}
          </p>
        </div>
        <Button
          disabled={data.loading || (!local && !account)}
          onClick={() => void refresh()}
          tip={t("Refresh planning dashboard")}
        >
          {data.loading ? <Spinner /> : <RefreshCw size={15} />}
        </Button>
      </header>
      <WorkspacePlanningSource
        source={source}
        choose={(value) => {
          setSource(value);
          setOnlyMine(false);
        }}
        create={() => {
          if (account) store.hostingHub.selectedAccountID = account.id;
          store.hostingHub.projectScope = effectiveScope;
          void store.hostingHub
            .selectProjectSource(source)
            .then(() => {store.hostingHub.requestProjectCreation(source==="local"?"local":"githubPrivate");store.navigate("projects");});
        }}
      />
      {!local && !available.length && !fixture ? (
        <p className="muted">
          {t("Connect a GitHub account to plan across your projects.")}
        </p>
      ) : (
        <>
          <WorkspacePlanningControls
            local={local}
            available={available}
            accountID={account?.id ?? ""}
            chooseAccount={setAccountID}
            repositoryScope={repositoryScope}
            scope={scope}
            chooseScope={setScope}
            data={data}
            chooseProject={chooseProject}
            loadMore={() => void load(true)}
            removeUnavailable={() => {
              const selected = data.selectedIDs.filter((id) =>
                data.projects.some((item) => item.id === id),
              );
              data.setSelected(selected);
              saveProjectPortfolioSelection(selectionContext, selected);
              void refresh();
            }}
          />
          {(local || account) &&
            !data.loading &&
            (readError || data.error || !data.projects.length) && (
              <Button
                size="small"
                onClick={() => {
                  if (account) store.hostingHub.selectedAccountID = account.id;
                  store.hostingHub.projectScope = effectiveScope;
                  void store.hostingHub
                    .selectProjectSource(source)
                    .then(() => store.navigate("projects"));
                }}
              >
                {t("Open project workspace")}
              </Button>
            )}
          {opening && (
            <div className="planning-opening" role="status">
              <Spinner />
              {t("Opening the selected task…")}
            </div>
          )}
          {(readError || data.error) && (
            <div className="planning-error" role="alert">
              {readError || data.error}
              <Button disabled={data.loading} onClick={() => void refresh()}>
                {t("Retry")}
              </Button>
            </div>
          )}
          {!!Object.keys(data.projectErrors).length && (
            <p className="planning-warning">
              {t(
                "Some projects could not be refreshed. Their last loaded tasks may be out of date.",
              )}
            </p>
          )}
          <div className="planning-metrics">
            {metrics.map(([label, count, key]) => (
              <button
                key={key}
                className={`${key} ${focus === key ? "active" : ""}`}
                onClick={() => {
                  setFocus(focus === key ? "focus" : key);
                  setMode("agenda");
                }}
              >
                <span>{t(label)}</span>
                <strong>{count}</strong>
              </button>
            ))}
          </div>
          <div className="planning-viewbar">
            <div role="group" aria-label={t("Planning view")}>
              {["agenda", "week", "projects"].map((value) => (
                <Button
                  size="small"
                  key={value}
                  kind={mode === value ? "primary" : undefined}
                  onClick={() => setMode(value)}
                >
                  {t(
                    value === "agenda"
                      ? "Agenda"
                      : value === "week"
                        ? "Week"
                        : "Projects",
                  )}
                </Button>
              ))}
            </div>
            <label className="planning-search">
              <Search size={14} />
              <input
                aria-label={t("Search tasks and projects")}
                placeholder={t("Search tasks and projects")}
                value={query}
                onChange={(event) => setQuery(event.target.value)}
              />
            </label>
            {!local&&<Button
              size="small"
              kind={onlyMine ? "primary" : undefined}
              onClick={() => setOnlyMine(!onlyMine)}
            >
              <Users size={13} />
              {t("Assigned to me")}
            </Button>}
          </div>
          <WorkspacePlanningViews
            mode={mode}
            matchesTask={matchesTask}
            filtered={!!query.trim() || onlyMine}
            agenda={agenda}
            tasks={tasks}
            data={data}
            settings={settings}
            today={today}
            anchor={anchor}
            setAnchor={setAnchor}
            focus={focus}
            setFocus={setFocus}
            opening={opening}
            openProject={openProject}
            loadMore={(id) => {
              setReadError("");
              void readAccess()
                .then((access) => data.loadMoreItems(access, context, id))
                .catch((error: unknown) => {
                  if (isCurrent()) setReadError(hubError(error));
                });
            }}
          />
          <footer>
            {t(
              local
                ? "Local project tasks are stored on this device and stay available offline."
                : "Loaded tasks from selected projects. Shared issues appear once, using their earliest active date.",
            )}
          </footer>
        </>
      )}
    </section>
  );
}
