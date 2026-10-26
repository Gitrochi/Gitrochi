import { ExternalLink, Settings2 } from "lucide-react";
import type { HubProjectView } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";
export function ProjectSavedViews({
  views,
  loading,
  error,
  selected,
  choose,
  manage,
  open,
  projectURL,
}: {
  views: HubProjectView[];
  loading: boolean;
  error: string;
  selected?: HubProjectView;
  choose: (view?: HubProjectView) => void;
  manage: () => void;
  open: (url: string) => void;
  projectURL: string;
}) {
  return (
    <div className="project-saved-views">
      <div>
        <label>
          {t("Shared view")}
          <select
            className="select"
            aria-label={t("Shared view")}
            value={selected?.id ?? ""}
            disabled={loading}
            onChange={(event) =>
              choose(views.find((view) => view.id === event.target.value))
            }
          >
            <option value="">{t("Local workspace")}</option>
            {views.map((view) => (
              <option value={view.id} key={view.id}>
                {view.name}
              </option>
            ))}
          </select>
        </label>
        {loading && <Spinner />}
        <Button size="small" onClick={manage}>
          <Settings2 size={12} />
          {t("Manage views")}
        </Button>
        {error && (
          <span className="hint">{t("Shared views could not be loaded.")}</span>
        )}
      </div>
      {selected && (
        <div className="project-view-context">
          {selected.filter ? (
            <span>
              {t("Saved filter: {0}", selected.filter)}
              <small>
                {t(
                  "Saved filters run in GitHub. Native filters apply to the items loaded here.",
                )}
              </small>
            </span>
          ) : (
            <span>
              {t(
                "Shared layout and loaded field configuration are applied locally.",
              )}
            </span>
          )}
          <Button
            size="small"
            onClick={() =>
              open(
                selected.number
                  ? `${projectURL.replace(/\/$/, "")}/views/${selected.number}`
                  : projectURL,
              )
            }
          >
            <ExternalLink size={12} />
            {t("Open shared view")}
          </Button>
        </div>
      )}
    </div>
  );
}
