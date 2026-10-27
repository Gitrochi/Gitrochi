import { t } from "@/shared/i18n";
import { HostingError } from "./hosting";
import { localProjects } from "../model/local-projects";
import { ensureHubCurrent, hubError, hubGraphql, hubUsesLocal, HubProjectActionDeniedError, HubProjectPermissionError, HubUncertainWriteError, type HubAccess, type HubDetail, type HubProjectField } from "./hub";

type ItemResponse = { projectV2Item?: { id?: string } };

/** macOS: createProjectTask. Assigns only the exact item returned by creation. */
export async function createHubProjectTask(c: HubAccess, detail: HubDetail, title: string, body = "", field?: HubProjectField, option?: string): Promise<void> {
  if (hubUsesLocal(c, detail.item)) {
    await localProjects.saveDraft(detail, title, body, undefined, field, option);
    ensureHubCurrent(c); return;
  }
  ensureHubCurrent(c);
  if (c.target.provider !== "github" || !detail.item.id) throw new Error(t("This action requires a GitHub project."));
  const name = title.trim();
  if (!name) throw new Error(t("A draft title is required."));
  const actual = field ? detail.fields.find(candidate => candidate.id === field.id) : undefined;
  if (field && (!actual || !actual.id || (actual.kind ?? (actual.options.length ? "singleSelect" : "unsupported")) !== "singleSelect" || option != null && (!option || !actual.options.some(value => value.id === option))) || !field && option != null) throw new Error(t("Select a loaded project field and item."));
  const projectID = detail.item.id, fieldID = actual?.id;
  let createdID: string;
  try {
    const result = await hubGraphql<{ addProjectV2DraftIssue?: { projectItem?: { id?: string } } }>(c, "mutation($input:AddProjectV2DraftIssueInput!){addProjectV2DraftIssue(input:$input){projectItem{id}}}", { input: { projectId: projectID, title: name, body } });
    const id = result.addProjectV2DraftIssue?.projectItem?.id;
    if (typeof id !== "string" || !id) throw new Error(t("The server returned an unexpected response."));
    createdID = id;
  } catch (error) {
    if (error instanceof HostingError && error.status >= 400 && error.status < 500 || error instanceof HubProjectPermissionError || error instanceof HubProjectActionDeniedError) throw error;
    throw new HubUncertainWriteError(`${hubError(error, c.token)}\n\n${t("The server may have accepted the last change. Refresh and check the remote item before trying again.")}`);
  }
  if (!fieldID) return;
  try {
    const input = { projectId: projectID, itemId: createdID, fieldId: fieldID };
    const assignment = option != null
      ? (await hubGraphql<{ updateProjectV2ItemFieldValue?: ItemResponse }>(c, "mutation($input:UpdateProjectV2ItemFieldValueInput!){updateProjectV2ItemFieldValue(input:$input){projectV2Item{id}}}", { input: { ...input, value: { singleSelectOptionId: option } } })).updateProjectV2ItemFieldValue
      : (await hubGraphql<{ clearProjectV2ItemFieldValue?: ItemResponse }>(c, "mutation($input:ClearProjectV2ItemFieldValueInput!){clearProjectV2ItemFieldValue(input:$input){projectV2Item{id}}}", { input })).clearProjectV2ItemFieldValue;
    if (assignment?.projectV2Item?.id !== createdID) throw new Error(t("The server returned an unexpected response."));
  } catch (error) {
    throw new HubUncertainWriteError(`${t("The task was created, but its column was not confirmed. Refresh the project before trying again.")}\n\n${hubError(error, c.token)}`);
  }
}
