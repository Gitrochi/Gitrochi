import { useState } from "react";
import { ExternalLink, Settings2, X } from "lucide-react";
import {
  saveHubProjectSettings,
  type HubDetail,
  type HubProjectSettingsInput,
  type HubProjectView,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import type { ProjectAsk } from "../lib/project-workspace";
import { ProjectFieldManager } from "./ProjectFieldManager";
import { ProjectViewManager } from "./ProjectViewManager";
export function ProjectSettings({
  detail,
  initialTab = "project",
  locked,
  ask,
  close,
  views,
  viewLoading,
  viewError,
  reloadViews,
  moreViews,
  loadMoreViews,
  open,
  safe,
}: {
  detail: HubDetail;
  initialTab?: "project" | "fields" | "views";
  locked: boolean;
  ask: ProjectAsk;
  close: () => void;
  views: HubProjectView[];
  viewLoading: boolean;
  viewError: string;
  reloadViews: () => Promise<void>;
  moreViews: boolean;
  loadMoreViews: () => Promise<void>;
  open: (url: string) => void;
  safe: (url: string) => boolean;
}) {
  const [tab, setTab] = useState<"project" | "fields" | "views">(initialTab),
    [input, setInput] = useState<HubProjectSettingsInput>({
      title: detail.item.title,
      shortDescription: detail.item.body,
      readme: String(detail.item.data.readme ?? ""),
      public: detail.item.data.public === true,
      closed: detail.item.data.closed === true,
    });
  return (
    <section className="project-settings" aria-label={t("Project settings")}>
      <div className="project-composer-heading">
        <div>
          <h3>
            <Settings2 size={15} />
            {t("Project settings")}
          </h3>
          <p>{t("Changes are shared with everyone who uses this project.")}</p>
        </div>
        <Button
          size="small"
          tip={t("Close project settings")}
          aria-label={t("Close project settings")}
          onClick={() => {
            ask.cancel?.();
            close();
          }}
        >
          <X size={15} />
        </Button>
      </div>
      <div
        className="project-composer-tabs"
        role="group"
        aria-label={t("Project settings section")}
      >
        {(["project", "fields", "views"] as const).map((value) => (
          <Button
            key={value}
            size="small"
            kind={tab === value ? "primary" : undefined}
            onClick={() => setTab(value)}
          >
            {t(
              value === "project"
                ? "Overview"
                : value === "fields"
                  ? "Project fields"
                  : "Shared views",
            )}
          </Button>
        ))}
      </div>
      {tab === "project" ? (
        <div className="project-management-editor">
          <label>
            {t("Project name")}
            <input
              className="input"
              disabled={locked}
              value={input.title}
              onChange={(event) =>
                setInput((current) => ({
                  ...current,
                  title: event.target.value,
                }))
              }
            />
          </label>
          <label>
            {t("Short description")}
            <input
              className="input"
              disabled={locked}
              value={input.shortDescription}
              onChange={(event) =>
                setInput((current) => ({
                  ...current,
                  shortDescription: event.target.value,
                }))
              }
            />
          </label>
          <label>
            {t("Project readme")}
            <textarea
              className="textarea"
              rows={5}
              disabled={locked}
              value={input.readme}
              onChange={(event) =>
                setInput((current) => ({
                  ...current,
                  readme: event.target.value,
                }))
              }
            />
          </label>
          <label className="project-setting-check">
            <input
              type="checkbox"
              disabled={locked}
              checked={input.public}
              onChange={(event) =>
                setInput((current) => ({
                  ...current,
                  public: event.target.checked,
                }))
              }
            />
            <span>
              <strong>{t("Public project")}</strong>
              <small>
                {t(
                  "Anyone can view a public project. Private repository items keep their own access rules.",
                )}
              </small>
            </span>
          </label>
          <label className="project-setting-check">
            <input
              type="checkbox"
              disabled={locked}
              checked={input.closed}
              onChange={(event) =>
                setInput((current) => ({
                  ...current,
                  closed: event.target.checked,
                }))
              }
            />
            <span>
              <strong>{t("Close project")}</strong>
              <small>
                {t("Closed projects keep their items and can be reopened.")}
              </small>
            </span>
          </label>
          <Button
            kind="primary"
            disabled={locked || !input.title.trim()}
            onClick={() =>
              ask(
                t("Save project settings?"),
                `${input.title}\n${input.public ? t("Public project") : t("Private project")}\n${input.closed ? t("Closed") : t("Open")}`,
                (access) => saveHubProjectSettings(access, detail, input),
              )
            }
          >
            {t("Review and save")}
          </Button>
        </div>
      ) : tab === "fields" ? (
        <ProjectFieldManager detail={detail} locked={locked} ask={ask} />
      ) : (
        <ProjectViewManager
          detail={detail}
          views={views}
          loading={viewLoading}
          error={viewError}
          locked={locked}
          ask={ask}
          reload={reloadViews}
          more={moreViews}
          loadMore={loadMoreViews}
        />
      )}
      <div className="project-settings-browser">
        <span>
          {t(
            "Manage workflows, access, insights, and advanced settings in GitHub.",
          )}
        </span>
        {safe(detail.item.url) && (
          <Button size="small" onClick={() => open(detail.item.url)}>
            <ExternalLink size={13} />
            {t("Open in browser")}
          </Button>
        )}
      </div>
    </section>
  );
}
