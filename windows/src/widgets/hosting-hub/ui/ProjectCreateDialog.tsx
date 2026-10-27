import { useEffect, useRef, useState } from "react";
import {
  accounts,
  createHubProject,
  hubError,
  HubUncertainWriteError,
  localProjects,
  type HostingHubStore,
  type HubProjectPlan,
} from "@/entities/hosting";
import { accountHost } from "@/entities/git";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button } from "@/shared/ui";
import {
  readCreationRecovery,
  saveCreationRecovery,
  clearCreationRecovery,
} from "../lib/project-creation-recovery";
import { useProjectCreationCapabilities } from "../model/use-project-creation-capabilities";
import {
  ProjectCreationChooser,
  type ProjectCreationMode,
} from "./ProjectCreationChooser";
import { ProjectCreateReview } from "./ProjectCreateReview";
const planName = (plan: HubProjectPlan | undefined) =>
  plan?.tier && plan.tier !== "unknown"
    ? {
        free: "GitHub Free",
        pro: "GitHub Pro",
        team: "GitHub Team",
        enterprise: "GitHub Enterprise",
        unknown: "",
      }[plan.tier]
    : (plan?.rawName ?? t("Not reported by GitHub"));
export function ProjectCreateDialog({
  hub,
  close,
  initialMode,
}: {
  hub: HostingHubStore;
  close: () => void;
  initialMode: ProjectCreationMode;
}) {
  useObserve(hub);
  useObserve(accounts);
  const [mode, setMode] = useState(initialMode),
    [title, setTitle] = useState(""),
    [description, setDescription] = useState(""),
    [saving, setSaving] = useState(false),
    [error, setError] = useState("");
  const [review, setReview] = useState<{
      title: string;
      context: string;
      account: string;
      owner: string;
      plan: string;
      isPublic: boolean;
    } | null>(null),
    active = useRef(true),
    capability = useProjectCreationCapabilities(hub, mode),
    context = hub.contextStamp;
  useEffect(() => {
    active.current = true;
    return () => {
      active.current = false;
    };
  }, []);
  useEffect(() => {
    setReview(null);
    setError("");
  }, [context, mode]);
  const choices = accounts.accounts.filter(
      (account) => account.provider === "github",
    ),
    account =
      hub.projectSource === "remote" && hub.account?.provider === "github"
        ? hub.account
        : null;
  const chooseMode = (value: ProjectCreationMode) => {
    setReview(null);
    setError("");
    setMode(value);
    if (value === "local") {
      void hub.selectProjectSource("local");
      return;
    }
    const first = choices[0];
    if (first && (!hub.account || hub.account.provider !== "github"))
      hub.selectedAccountID = first.id;
    void hub.selectProjectSource("remote");
  };
  useEffect(() => {
    if (initialMode !== "local" && hub.projectSource !== "remote")
      chooseMode(initialMode);
  }, []);
  const recoveryKey = account
      ? JSON.stringify([account.id, accountHost(account), hub.projectOwner])
      : "",
    recovery = mode === "local" ? undefined : readCreationRecovery(recoveryKey);
  const reconcile = async () => {
    const expected = hub.contextStamp;
    setSaving(true);
    setError("");
    try {
      await hub.load();
      let pages = 1;
      while (
        hub.more &&
        !hub.error &&
        pages < 100 &&
        hub.contextStamp === expected
      ) {
        const cursor = hub.cursor;
        await hub.load(true);
        pages++;
        if (hub.cursor === cursor && hub.more) break;
      }
      if (!active.current || hub.contextStamp !== expected) return;
      if (hub.error || hub.more)
        throw new Error(
          hub.error ??
            t("Finish refreshing all projects before creating another one."),
        );
      clearCreationRecovery(recoveryKey);
      setError(
        t(
          "Projects refreshed. Check existing projects before creating another one.",
        ),
      );
    } catch (caught) {
      if (active.current && hub.contextStamp === expected)
        setError(hubError(caught));
    } finally {
      if (active.current) setSaving(false);
    }
  };
  const permission =
    !capability.value?.viewerVerified ||
    !capability.value.ownerID ||
    capability.value?.canCreate === false ||
    (mode === "githubPublic" && capability.value?.canPublish === false)
      ? "denied"
      : capability.value?.canCreate === true &&
          (mode !== "githubPublic" || capability.value?.canPublish === true)
        ? "allowed"
        : "unknown";
  const submit = async () => {
    setError("");
    if (mode === "local") {
      setSaving(true);
      const expected = hub.contextStamp;
      try {
        const item = await localProjects.create(title, description);
        if (!active.current || hub.contextStamp !== expected) return;
        await hub.selectProjectSource("local");
        await hub.select(item);
        if (active.current) close();
      } catch (caught) {
        if (active.current) setError(hubError(caught));
      } finally {
        if (active.current) setSaving(false);
      }
      return;
    }
    if (
      recovery ||
      !account ||
      capability.phase !== "ready" ||
      permission === "denied"
    )
      return;
    setReview({
      title: title.trim(),
      context: hub.actionStamp,
      account: `@${account.username} · ${accountHost(account)}`,
      owner: capability.value?.ownerLogin ?? hub.projectOwner,
      plan: planName(capability.value?.ownerPlan),
      isPublic: mode === "githubPublic",
    });
  };
  const confirm = async () => {
    if (
      !review ||
      hub.actionStamp !== review.context ||
      hub.uncertainWrite ||
      !!recovery
    )
      return;
    let created: Awaited<ReturnType<typeof createHubProject>> | undefined;
    const ok = await hub.action(async (access) => {
      try {
        created = await createHubProject(access, review.title, review.isPublic);
      } catch (caught) {
        if (caught instanceof HubUncertainWriteError)
          saveCreationRecovery(recoveryKey, caught.createdProject?.id);
        throw caught;
      }
    }, "list");
    if (!active.current) return;
    if (ok && created) {
      await hub.select(created);
      if (active.current) close();
    } else setError(hub.error ?? t("The project could not be created."));
  };
  const busy = saving || hub.busy;
  if (review)
    return (
      <ProjectCreateReview
        {...review}
        busy={busy}
        disabled={
          hub.actionStamp !== review.context || hub.uncertainWrite || !!recovery
        }
        error={error || hub.error || undefined}
        confirm={() => void confirm()}
        cancel={() => {
          setReview(null);
          setError("");
        }}
      />
    );
  return (
    <ProjectCreationChooser
      blocked={!!recovery}
      recovery={
        recovery ? (
          <div className="project-create-error" role="alert">
            <p>
              {t(
                "Refresh and check existing projects before creating another one.",
              )}
            </p>
            <Button disabled={busy} onClick={() => void reconcile()}>
              {t("Refresh projects")}
            </Button>
          </div>
        ) : undefined
      }
      mode={mode}
      chooseMode={chooseMode}
      title={title}
      setTitle={setTitle}
      description={description}
      setDescription={setDescription}
      accountLabel={
        account ? `@${account.username} · ${accountHost(account)}` : undefined
      }
      ownerLabel={
        capability.value?.ownerLogin ?? (account ? hub.projectOwner : undefined)
      }
      capability={{
        phase: capability.phase,
        planName: planName(capability.value?.ownerPlan),
        accountPlanName: planName(capability.value?.accountPlan),
        limits: capability.value
          ? `${t("{0} fields", capability.value.limits.fields)} · ${capability.value.limits.autoAddWorkflows === null ? t("Workflow limit not reported") : t("{0} auto-add workflows", capability.value.limits.autoAddWorkflows)}`
          : undefined,
        permission,
        message: capability.error ?? capability.value?.notice ?? undefined,
      }}
      retry={capability.retry}
      busy={busy}
      error={error || hub.error || undefined}
      review={() => void submit()}
      close={close}
      openPlans={() =>
        void ipc.openUrl(
          "https://docs.github.com/en/issues/planning-and-tracking-with-projects/learning-about-projects/about-projects",
        )
      }
      accountControls={
        <>
          <label>
            <span>{t("GitHub account")}</span>
            <select
              className="select"
              aria-label={t("Project creation account")}
              value={account?.id ?? ""}
              disabled={busy}
              onChange={(event) => {
                hub.projectScope = "personal";
                void hub.selectAccount(event.target.value);
              }}
            >
              {!choices.length && (
                <option value="">{t("No connected account")}</option>
              )}
              {choices.map((value) => (
                <option key={value.id} value={value.id}>
                  @{value.username} · {accountHost(value)}
                </option>
              ))}
            </select>
          </label>
          {account && (
            <label>
              <span>{t("Project owner")}</span>
              <select
                className="select"
                aria-label={t("Project creation owner")}
                value={hub.projectEffectiveScope}
                disabled={busy}
                onChange={(event) =>
                  void hub.selectProjectScope(
                    event.target.value as "personal" | "repository",
                  )
                }
              >
                {hub.projectRepositoryOwner && (
                  <option value="repository">
                    {hub.projectRepositoryOwner}
                  </option>
                )}
                <option value="personal">{account.username}</option>
              </select>
            </label>
          )}
          {!choices.length && (
            <Button
              size="small"
              onClick={() =>
                window.dispatchEvent(
                  new CustomEvent("gitrochi-open-settings", {
                    detail: "accounts",
                  }),
                )
              }
            >
              {t("Open account settings")}
            </Button>
          )}
        </>
      }
    />
  );
}
