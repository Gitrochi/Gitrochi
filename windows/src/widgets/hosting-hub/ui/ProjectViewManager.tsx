import { useState } from "react";
import { Plus, Trash2 } from "lucide-react";
import {
  saveHubProjectView,
  deleteHubProjectView,
  type HubDetail,
  type HubProjectView,
  type HubProjectViewInput,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";
import type { ProjectAsk } from "../lib/project-workspace";
export function ProjectViewManager({
  detail,
  views,
  loading,
  error,
  locked,
  ask,
  reload,
  more,
  loadMore,
}: {
  detail: HubDetail;
  views: HubProjectView[];
  loading: boolean;
  error: string;
  locked: boolean;
  ask: ProjectAsk;
  reload: () => Promise<void>;
  more: boolean;
  loadMore: () => Promise<void>;
}) {
  const [editing, setEditing] = useState<HubProjectView | null | undefined>(
      undefined,
    ),
    [input, setInput] = useState<HubProjectViewInput>({
      name: "",
      layout: "BOARD_LAYOUT",
      filter: "",
      visibleFieldIDs: [],
    });
  const edit = (view: HubProjectView | null) => {
    setEditing(view);
    setInput(
      view
        ? {
            name: view.name,
            layout: view.layout,
            filter: view.filter,
            visibleFieldIDs: [...view.visibleFieldIDs],
          }
        : {
            name: "",
            layout: "BOARD_LAYOUT",
            filter: "",
            visibleFieldIDs: detail.fields.map((field) => field.id),
          },
    );
  };
  return (
    <div className="project-management-section">
      <div className="project-management-section-head">
        <div>
          <h3>{t("Shared views")}</h3>
          <p>{t("Views are saved to GitHub and shared with your team.")}</p>
        </div>
        <Button size="small" disabled={locked} onClick={() => edit(null)}>
          <Plus size={13} />
          {t("New shared view")}
        </Button>
      </div>
      {error && (
        <p className="error-text" role="alert">
          {error}
          <Button size="small" onClick={() => void reload()}>
            {t("Retry")}
          </Button>
        </p>
      )}
      {editing !== undefined && (
        <div className="project-management-editor">
          <div className="row">
            <label>
              {t("View name")}
              <input
                className="input"
                disabled={locked}
                value={input.name}
                onChange={(event) =>
                  setInput((current) => ({
                    ...current,
                    name: event.target.value,
                  }))
                }
              />
            </label>
            <label>
              {t("Layout")}
              <select
                className="select"
                disabled={locked}
                value={input.layout}
                onChange={(event) =>
                  setInput((current) => ({
                    ...current,
                    layout: event.target.value as HubProjectViewInput["layout"],
                  }))
                }
              >
                <option value="BOARD_LAYOUT">{t("Board")}</option>
                <option value="TABLE_LAYOUT">{t("List")}</option>
                <option value="ROADMAP_LAYOUT">{t("Timeline")}</option>
              </select>
            </label>
          </div>
          <label>
            {t("GitHub filter")}
            <input
              className="input mono"
              disabled={locked}
              value={input.filter}
              placeholder="is:open assignee:@me"
              onChange={(event) =>
                setInput((current) => ({
                  ...current,
                  filter: event.target.value,
                }))
              }
            />
          </label>
          <p className="hint">
            {t(
              "Saved filters run in GitHub. Native filters apply to the items loaded here.",
            )}
          </p>
          <fieldset className="project-visible-fields">
            <legend>{t("Visible fields")}</legend>
            {detail.fields.map((field) => (
              <label key={field.id}>
                <input
                  type="checkbox"
                  disabled={locked}
                  checked={input.visibleFieldIDs.includes(field.id)}
                  onChange={(event) =>
                    setInput((current) => ({
                      ...current,
                      visibleFieldIDs: event.target.checked
                        ? [...current.visibleFieldIDs, field.id]
                        : current.visibleFieldIDs.filter(
                            (id) => id !== field.id,
                          ),
                    }))
                  }
                />
                {field.name}
              </label>
            ))}
          </fieldset>
          <div className="row">
            <Button
              kind="primary"
              size="small"
              disabled={locked || !input.name.trim()}
              onClick={() =>
                ask(
                  editing
                    ? t("Save shared view changes?")
                    : t("Create shared view?"),
                  `${input.name}\n${input.filter}`,
                  async (access) => {
                    await saveHubProjectView(
                      access,
                      detail,
                      input,
                      editing ?? undefined,
                    );
                    setEditing(undefined);
                    await reload();
                  },
                )
              }
            >
              {t("Review and save")}
            </Button>
            <Button
              size="small"
              disabled={locked}
              onClick={() => {
                ask.cancel?.();
                setEditing(undefined);
              }}
            >
              {t("Cancel")}
            </Button>
          </div>
        </div>
      )}
      <div className="project-field-catalog">
        {views.map((view) => (
          <div key={view.id}>
            <span>
              <strong>{view.name}</strong>
              <small>
                {view.layout === "BOARD_LAYOUT"
                  ? t("Board")
                  : view.layout === "ROADMAP_LAYOUT"
                    ? t("Timeline")
                    : t("List")}
                {view.filter ? ` · ${view.filter}` : ""}
              </small>
            </span>
            <Button size="small" disabled={locked} onClick={() => edit(view)}>
              {t("Edit")}
            </Button>
            <Button
              size="small"
              tip={t("Delete view")}
              aria-label={t("Delete view")}
              disabled={locked}
              onClick={() =>
                ask(
                  t("Delete this shared view?"),
                  view.name,
                  async (access) => {
                    await deleteHubProjectView(access, detail, view);
                    await reload();
                  },
                )
              }
            >
              <Trash2 size={13} />
            </Button>
          </div>
        ))}
      </div>
      {loading ? (
        <Spinner />
      ) : (
        more && (
          <Button
            size="small"
            disabled={locked}
            onClick={() => void loadMore()}
          >
            {t("Load more")}
          </Button>
        )
      )}
      <p className="hint">
        {t("Grouping and sorting for shared views are managed in GitHub.")}
      </p>
    </div>
  );
}
