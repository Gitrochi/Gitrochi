import { Cloud, HardDrive, Plus } from "lucide-react";
import { accountHost, type HostAccount } from "@/entities/git";
import type { ProjectPortfolioState } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
export function WorkspacePlanningControls({
  local = false,
  available,
  accountID,
  chooseAccount,
  repositoryScope,
  scope,
  chooseScope,
  data,
  chooseProject,
  loadMore,
  removeUnavailable,
}: {
  local?: boolean;
  available: HostAccount[];
  accountID: string;
  chooseAccount: (id: string) => void;
  repositoryScope: boolean;
  scope: "personal" | "repository";
  chooseScope: (value: "personal" | "repository") => void;
  data: ProjectPortfolioState;
  chooseProject: (id: string, checked: boolean) => void;
  loadMore: () => void;
  removeUnavailable: () => void;
}) {
  return (
    <div className="planning-controls">
      {!local && (
        <select
          className="select"
          aria-label={t("Planning account")}
          value={accountID}
          onChange={(event) => chooseAccount(event.target.value)}
        >
          {available.map((value) => (
            <option value={value.id} key={value.id}>
              @{value.username} · {accountHost(value)}
            </option>
          ))}
        </select>
      )}
      {!local && repositoryScope && (
        <select
          className="select"
          aria-label={t("Project scope")}
          value={scope}
          onChange={(event) =>
            chooseScope(event.target.value as "personal" | "repository")
          }
        >
          <option value="personal">{t("My projects")}</option>
          <option value="repository">{t("Repository owner projects")}</option>
        </select>
      )}
      <details className="planning-project-picker">
        <summary>
          {t("Choose projects")} <b>{data.selectedIDs.length}</b>
        </summary>
        <div>
          {data.projects.map((item) => (
            <label key={item.id}>
              <input
                type="checkbox"
                disabled={data.loading}
                checked={data.selectedIDs.includes(item.id)}
                onChange={(event) =>
                  chooseProject(item.id, event.target.checked)
                }
              />
              {item.title}
            </label>
          ))}
          {!data.loading &&
            data.selectedIDs.some(
              (id) => !data.projects.some((item) => item.id === id),
            ) && (
              <Button size="small" onClick={removeUnavailable}>
                {t("Remove unavailable selections")}
              </Button>
            )}
          {data.more && (
            <Button disabled={data.loading} onClick={loadMore}>
              {t("Load more projects")}
            </Button>
          )}
        </div>
      </details>
    </div>
  );
}

export function WorkspacePlanningSource({
  source,
  choose,
  create,
}: {
  source: "local" | "remote";
  choose: (source: "local" | "remote") => void;
  create: () => void;
}) {
  return (
    <div className="planning-sourcebar">
      <div
        className="project-source-switch"
        role="group"
        aria-label={t("Project source")}
      >
        <Button
          size="small"
          kind={source === "local" ? "primary" : undefined}
          onClick={() => choose("local")}
        >
          <HardDrive size={13} />
          {t("Local")}
        </Button>
        <Button
          size="small"
          kind={source === "remote" ? "primary" : undefined}
          onClick={() => choose("remote")}
        >
          <Cloud size={13} />
          {t("GitHub")}
        </Button>
      </div>
      <Button size="small" kind="primary" onClick={create}>
        <Plus size={13} />
        {t("Create a project")}
      </Button>
    </div>
  );
}
