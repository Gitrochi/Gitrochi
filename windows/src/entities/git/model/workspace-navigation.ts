export const repositorySections = ["changes", "commits", "branches", "compare", "rebase", "code"] as const;
export type RepositorySection = typeof repositorySections[number];
export const workspaceDestinations = ["home", "repositories", "repository", ...repositorySections, "inbox", "myWork", "pullRequests", "issues", "actions", "releases", "projects", "organizations", "gists", "assistant", "agents", "worktrees", "operations"] as const;
export type WorkspaceDestination = typeof workspaceDestinations[number];
export interface WorkspaceLocation { destination: WorkspaceDestination; repositorySection: RepositorySection }
export const repositoryDestinations = new Set<WorkspaceDestination>(["repository", ...repositorySections, "pullRequests", "actions", "assistant", "agents", "worktrees"]);
export function isWorkspaceDestination(value: unknown): value is WorkspaceDestination { return typeof value === "string" && (workspaceDestinations as readonly string[]).includes(value); }
export function isRepositorySection(value: unknown): value is RepositorySection { return typeof value === "string" && (repositorySections as readonly string[]).includes(value); }
export function workspaceLocation(destination: WorkspaceDestination, section: RepositorySection = "changes"): WorkspaceLocation {
  return { destination: isRepositorySection(destination) ? "repository" : destination, repositorySection: isRepositorySection(destination) ? destination : section };
}
