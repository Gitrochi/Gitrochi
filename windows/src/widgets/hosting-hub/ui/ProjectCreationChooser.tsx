import type { ReactNode } from "react";
import {
  Check,
  CircleHelp,
  Cloud,
  Globe2,
  HardDrive,
  LockKeyhole,
  RefreshCw,
  ShieldCheck,
  Sparkles,
  X,
} from "lucide-react";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";
import "./project-creation.css";
export type ProjectCreationMode = "local" | "githubPrivate" | "githubPublic";
export interface ProjectCreationCapability {
  phase: "idle" | "loading" | "ready" | "error";
  planName?: string;
  accountPlanName?: string;
  limits?: string;
  permission: "allowed" | "denied" | "unknown";
  message?: string;
}
export function ProjectCreationChooser({
  mode,
  chooseMode,
  title,
  setTitle,
  description,
  setDescription,
  accountControls,
  accountLabel,
  ownerLabel,
  capability,
  retry,
  busy,
  error,
  review,
  close,
  openPlans,
  recovery,
  blocked = false,
}: {
  mode: ProjectCreationMode;
  chooseMode: (mode: ProjectCreationMode) => void;
  title: string;
  setTitle: (title: string) => void;
  description: string;
  setDescription: (description: string) => void;
  accountControls: ReactNode;
  accountLabel?: string;
  ownerLabel?: string;
  capability: ProjectCreationCapability;
  retry: () => void;
  busy: boolean;
  error?: string;
  review: () => void;
  close: () => void;
  openPlans: () => void;
  recovery?: ReactNode;
  blocked?: boolean;
}) {
  const local = mode === "local",
    ready =
      local ||
      (!!accountLabel &&
        capability.phase === "ready" &&
        capability.permission !== "denied");
  const options = [
    {
      id: "local" as const,
      label: t("Local project"),
      eyebrow: t("Start immediately"),
      description: t(
        "Plan privately on this device. No account or network connection is needed.",
      ),
      icon: HardDrive,
      badge: t("Always available"),
    },
    {
      id: "githubPrivate" as const,
      label: t("Private GitHub project"),
      eyebrow: t("Share with your team"),
      description: t(
        "Keep the project private and collaborate with people who have access.",
      ),
      icon: LockKeyhole,
      badge: t("Available on GitHub Free"),
    },
    {
      id: "githubPublic" as const,
      label: t("Public GitHub project"),
      eyebrow: t("Plan in the open"),
      description: t(
        "Publish the project for anyone to view. Repository items keep their own access rules.",
      ),
      icon: Globe2,
      badge: t("Available on GitHub Free"),
    },
  ];
  return (
    <section
      className="project-create-chooser"
      role="dialog"
      aria-modal="true"
      aria-label={t("Create a project")}
    >
      <header>
        <div>
          <span className="project-create-eyebrow">
            <Sparkles size={14} />
            {t("A home for your next idea")}
          </span>
          <h2>{t("Where should this project live?")}</h2>
          <p>
            {t(
              "Choose how you want to plan. You can manage local and GitHub projects in the same app.",
            )}
          </p>
        </div>
        <Button
          size="small"
          tip={t("Close project creation")}
          aria-label={t("Close project creation")}
          disabled={busy}
          onClick={close}
        >
          <X size={16} />
        </Button>
      </header>
      <div
        className="project-create-options"
        role="group"
        aria-label={t("Project storage and visibility")}
      >
        {options.map((option) => (
          <button
            key={option.id}
            className={`project-create-mode ${mode === option.id ? "selected" : ""}`}
            disabled={busy}
            aria-pressed={mode === option.id}
            onClick={() => chooseMode(option.id)}
          >
            <span className="project-create-mode-top">
              <span>
                <option.icon size={21} />
              </span>
              {mode === option.id && <Check size={16} />}
            </span>
            <small>{option.eyebrow}</small>
            <strong>{option.label}</strong>
            <p>{option.description}</p>
            <span className="project-create-badge">{option.badge}</span>
          </button>
        ))}
      </div>
      <div className="project-create-content">
        <div className="project-create-fields">
          <label>
            <span>{t("Project name")}</span>
            <input
              className="input"
              aria-label={t("Project name")}
              autoFocus
              value={title}
              disabled={busy}
              placeholder={t("Give the work a clear name")}
              onChange={(event) => setTitle(event.target.value)}
            />
          </label>
          {local && (
            <label>
              <span>{t("Short description")}</span>
              <textarea
                className="textarea"
                aria-label={t("Project description")}
                rows={3}
                value={description}
                disabled={busy}
                placeholder={t("What will this project help you achieve?")}
                onChange={(event) => setDescription(event.target.value)}
              />
            </label>
          )}
          {!local && accountControls}
        </div>
        <aside className="project-create-guidance">
          <h3>
            {local ? <HardDrive size={16} /> : <Cloud size={16} />}{" "}
            {local ? t("Your device, your workspace") : t("GitHub readiness")}
          </h3>
          {local ? (
            <>
              <p>
                {t(
                  "Tasks, statuses, priorities, and dates are saved locally and remain editable offline.",
                )}
              </p>
              <span className="project-create-status success">
                <ShieldCheck size={14} />
                {t("No GitHub permission required")}
              </span>
              <p className="project-create-disclosure">
                {t(
                  "This does not create a GitHub project or sync data to another device.",
                )}
              </p>
            </>
          ) : (
            <>
              <dl>
                <div>
                  <dt>{t("Account")}</dt>
                  <dd>{accountLabel ?? t("No connected account")}</dd>
                </div>
                <div>
                  <dt>{t("Owner")}</dt>
                  <dd>{ownerLabel ?? t("Choose an owner")}</dd>
                </div>
                <div>
                  <dt>{t("Owner plan")}</dt>
                  <dd>
                    {capability.phase === "loading" ? (
                      <Spinner />
                    ) : (
                      (capability.planName ?? t("Not reported by GitHub"))
                    )}
                  </dd>
                </div>
                <div>
                  <dt>{t("Account plan")}</dt>
                  <dd>
                    {capability.phase === "loading" ? (
                      <Spinner />
                    ) : (
                      (capability.accountPlanName ??
                      t("Not reported by GitHub"))
                    )}
                  </dd>
                </div>
                {capability.limits && (
                  <div>
                    <dt>{t("Project limits")}</dt>
                    <dd>{capability.limits}</dd>
                  </div>
                )}
                <div>
                  <dt>{t("Project creation permission")}</dt>
                  <dd>
                    {capability.phase === "loading"
                      ? t("Checking…")
                      : capability.permission === "allowed"
                        ? t("Confirmed")
                        : capability.permission === "denied"
                          ? t("Not available with this access")
                          : t("Not confirmed")}
                  </dd>
                </div>
              </dl>
              {capability.message && (
                <p className="project-create-disclosure" role="status">
                  {capability.message}
                </p>
              )}
              <p className="project-create-disclosure">
                <CircleHelp size={13} />
                {t(
                  "Free and paid GitHub accounts can create private and public projects. Token permissions, repository access, and organization policy are checked separately.",
                )}
              </p>
              {capability.phase === "ready" && (
                <Button size="small" onClick={retry} disabled={busy}>
                  <RefreshCw size={12} />
                  {t("Check access again")}
                </Button>
              )}
              <button className="project-create-plans" onClick={openPlans}>
                {t("Review GitHub plan details")}
              </button>
            </>
          )}
        </aside>
      </div>
      {!local && mode === "githubPublic" && (
        <div className="project-create-public-note">
          <Globe2 size={15} />
          {t(
            "Anyone can view a public project. Review the project name and owner before creating it.",
          )}
        </div>
      )}
      {error && (
        <div className="project-create-error" role="alert">
          {error}
        </div>
      )}
      {recovery}
      <footer>
        <span>
          {local
            ? t("Stored on this device")
            : mode === "githubPrivate"
              ? t("Private on GitHub")
              : t("Public on GitHub")}
        </span>
        <div>
          <Button disabled={busy} onClick={close}>
            {t("Cancel")}
          </Button>
          <Button
            kind="primary"
            disabled={busy || !title.trim() || !ready || blocked}
            onClick={review}
          >
            {busy ? <Spinner /> : null}
            {local ? t("Create local project") : t("Review and create")}
          </Button>
        </div>
      </footer>
    </section>
  );
}
