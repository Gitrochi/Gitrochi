import { Plus, ExternalLink, Settings2 } from "lucide-react";
import type { HubDetail } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { projectKind } from "../lib/project-workspace";
export function ProjectHero({
  detail,
  gitlab,
  locked,
  open,
  safe,
  add,
  settings,
}: {
  detail: HubDetail;
  gitlab: boolean;
  locked: boolean;
  open: (url: string) => void;
  safe: (url: string) => boolean;
  add: () => void;
  settings: () => void;
}) {
  const activeRows = detail.rows.filter((row) => !row.archived);
  return (
    <div className="project-hero">
      <div className="project-hero-main">
        <div className="project-eyebrow">
          <span className="project-live-dot" />
          {gitlab ? t("GitLab issue board") : t("GitHub Projects")}
          <span>·</span>
          {t("Work connected to your code")}
        </div>
        <h1>{detail.item.title}</h1>
        <p>
          {detail.item.body ||
            t(
              "From the next idea to the next release, keep the work and the code together.",
            )}
        </p>
        <div className="project-hero-actions">
          <Button kind="primary" disabled={locked} onClick={() => add()}>
            <Plus size={15} />
            {t("Add item")}
          </Button>
          {safe(detail.item.url) && (
            <Button size="small" onClick={() => open(detail.item.url)}>
              <ExternalLink size={13} />
              {t("Open in browser")}
            </Button>
          )}
          {!gitlab && (
            <Button size="small" onClick={settings}>
              <Settings2 size={13} />
              {t("Project settings")}
            </Button>
          )}
        </div>
      </div>
      <div className="project-summary" aria-label={t("Loaded project summary")}>
        <div>
          <strong>{activeRows.length}</strong>
          <span>{t("Active items")}</span>
        </div>
        <div>
          <strong>
            {activeRows.filter((row) => projectKind(row) === "issue").length}
          </strong>
          <span>{t("Issues")}</span>
        </div>
        <div>
          <strong>
            {
              activeRows.filter((row) => projectKind(row) === "pullRequest")
                .length
            }
          </strong>
          <span>{t("Pull requests")}</span>
        </div>
        <div>
          <strong>
            {activeRows.filter((row) => projectKind(row) === "draft").length}
          </strong>
          <span>{t("Drafts")}</span>
        </div>
        <small>
          {detail.more
            ? t("More items are available. Metrics cover loaded pages.")
            : t("Counts show active items from loaded pages.")}
        </small>
      </div>
    </div>
  );
}
