import type { ProjectTaskReference } from "@/entities/git";
interface ProjectBranchReference {
  path: string;
  branch: string;
  task: ProjectTaskReference;
}
const storageKey = "gitrochi.projectBranches.v1";
function references(): ProjectBranchReference[] {
  try {
    const value: unknown = JSON.parse(localStorage.getItem(storageKey) ?? "[]");
    return Array.isArray(value)
      ? value.filter(
          (item): item is ProjectBranchReference =>
            !!item &&
            typeof item.path === "string" &&
            typeof item.branch === "string" &&
            typeof item.task?.id === "string" &&
            typeof item.task?.repository === "string" &&
            typeof item.task?.host === "string",
        )
      : [];
  } catch {
    return [];
  }
}
/** Called only after Git confirms that a branch was created in the captured repository. */
export function rememberProjectBranch(
  path: string,
  branch: string,
  task: ProjectTaskReference,
): void {
  try {
    const values = references().filter(
      (item) => item.path !== path || item.branch !== branch,
    );
    localStorage.setItem(
      storageKey,
      JSON.stringify([...values, { path, branch, task }].slice(-2000)),
    );
  } catch {
    /* Branch creation remains successful when local storage is unavailable. */
  }
}
export function projectTaskBranches(
  path: string,
  taskID: string,
  repository: string,
  host: string,
): string[] {
  return references()
    .filter(
      (item) =>
        item.path === path &&
        item.task.id === taskID &&
        item.task.repository.toLocaleLowerCase() ===
          repository.toLocaleLowerCase() &&
        item.task.host.toLocaleLowerCase() === host.toLocaleLowerCase(),
    )
    .map((item) => item.branch);
}

/** Only a branch in the same local repository and hosting context can supply a PR handoff. */
export function projectBranchTask(path: string, branch: string, repository: string, host: string): ProjectTaskReference | null {
  return references().find(item => item.path === path && item.branch === branch && item.task.repository.toLowerCase() === repository.toLowerCase() && item.task.host.toLowerCase() === host.toLowerCase())?.task ?? null;
}
export function projectIssueBranches(path: string, task: ProjectTaskReference): string[] {
  return references().filter(item => item.path === path && item.task.number === task.number && item.task.repository.toLowerCase() === task.repository.toLowerCase() && item.task.host.toLowerCase() === task.host.toLowerCase()).map(item => item.branch);
}
