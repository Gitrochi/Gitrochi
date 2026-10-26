/**
 * The pages of a repository window. Repository is the three-column screen (branches | graph | inspector);
 * the rest are full-width pages. (macOS: Core/WorkspaceNavigation.swift)
 */
export const workspaceDestinations = ["home", "repository", "compare", "rebase", "code", "pullRequests", "issues", "actions", "account", "flows"] as const;
export type WorkspaceDestination = (typeof workspaceDestinations)[number];
/** Pages that need an open repository. Home, Issues and Account work from an account alone. */
export const repositoryDestinations: ReadonlySet<WorkspaceDestination> = new Set<WorkspaceDestination>(["repository", "compare", "rebase", "code", "pullRequests", "actions", "flows"]);
export function isWorkspaceDestination(value: unknown): value is WorkspaceDestination {
  return typeof value === "string" && (workspaceDestinations as readonly string[]).includes(value);
}
/** The page a repository opens on: the saved one when it is valid, otherwise the repository screen (Home without a repository). */
export function restoredDestination(saved: unknown, hasRepository: boolean): WorkspaceDestination {
  const page = isWorkspaceDestination(saved) ? saved : hasRepository ? "repository" : "home";
  return repositoryDestinations.has(page) && !hasRepository ? "home" : page;
}
