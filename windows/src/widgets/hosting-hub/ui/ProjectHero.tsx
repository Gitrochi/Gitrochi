import { Plus, ExternalLink, Settings2, Globe2, LockKeyhole } from "lucide-react";
import type { HubDetail } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
export function ProjectHero({
  detail,
  gitlab,
  locked,
  open,
  safe,
  add,
  settings,
  localProject = false,
}: {
  detail: HubDetail;
  gitlab: boolean;
  locked: boolean;
  open: (url: string) => void;
  safe: (url: string) => boolean;
  add: () => void;
  settings: () => void;
  planning?: boolean;
  localProject?: boolean;
}) {
  const rows = detail.rows.filter((row) => !row.archived),
    completed = rows.filter(
      (row) =>
        /^(closed|merged)$/i.test(row.state ?? "") ||
        (localProject && row.statuses["local-status"] === "local-done"),
    ).length;
  return (
    <header className="project-hero">
      <div className="project-hero-main">
        <div className="project-title-line">
          <h1>{detail.item.title}</h1>
          <span className="project-source-badge">
            {localProject
              ? t("Local project")
              : gitlab
                ? t("GitLab issue board")
                : t("GitHub Projects")}
          </span>
        </div>
        {detail.item.body && <p>{detail.item.body}</p>}
        <div className="project-title-meta">
          <span>{t("{0} tasks", rows.length)}</span>
          <span>·</span>
          <span>{t("{0} completed", completed)}</span>
          {detail.more && <span>· {t("Loaded items")}</span>}
          {!gitlab && !localProject && typeof detail.item.data.public === "boolean" && <span className="project-visibility">
            {detail.item.data.public ? <Globe2 size={11} /> : <LockKeyhole size={11} />}{t(detail.item.data.public ? "Public project" : "Private project")}
          </span>}
          {localProject && (
            <span className="project-device-note">
              {t("Private on this device")}
            </span>
          )}
        </div>
      </div>
      <div className="project-hero-actions">
        <Button kind="primary" disabled={locked} onClick={add}>
          <Plus size={15} />
          {t(localProject ? "Add task" : "Add item")}
        </Button>
        {safe(detail.item.url) && (
          <Button
            size="small"
            tip={t("Open in browser")}
            aria-label={t("Open in browser")}
            onClick={() => open(detail.item.url)}
          >
            <ExternalLink size={15} />
          </Button>
        )}
        {!gitlab && (
          <Button
            size="small"
            tip={t("Project settings")}
            aria-label={t("Project settings")}
            onClick={settings}
          >
            <Settings2 size={15} />
          </Button>
        )}
      </div>
    </header>
  );
}
