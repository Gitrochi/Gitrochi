/**
 * The pages of a repository window. Repository is the three-column screen (branches | graph | inspector);
 * the rest are full-width pages. (macOS: Core/WorkspaceNavigation.swift)
 */
export const workspaceDestinations = ["home", "repository", "compare", "rebase", "code", "pullRequests", "issues", "actions", "releases", "projects", "account", "flows"] as const;
export type WorkspaceDestination = (typeof workspaceDestinations)[number];
/** Pages that need an open repository. Home, Issues, Releases, Projects and Account work from an account alone. */
export const repositoryDestinations: ReadonlySet<WorkspaceDestination> = new Set<WorkspaceDestination>(["repository", "compare", "rebase", "code", "pullRequests", "actions", "flows"]);
/** Pages the repository screen links to (request and issue rows, a commit's CI badge, the tags); opened from there, they offer the way back (macOS: returnsToRepository) */
export const returnsToRepository: ReadonlySet<WorkspaceDestination> = new Set<WorkspaceDestination>(["pullRequests", "issues", "actions", "releases"]);
export function isWorkspaceDestination(value: unknown): value is WorkspaceDestination {
  return typeof value === "string" && (workspaceDestinations as readonly string[]).includes(value);
}
/** The page a repository opens on: the saved one when it is valid, otherwise the repository screen (Home without a repository). */
export function restoredDestination(saved: unknown, hasRepository: boolean): WorkspaceDestination {
  const page = isWorkspaceDestination(saved) ? saved : hasRepository ? "repository" : "home";
  return repositoryDestinations.has(page) && !hasRepository ? "home" : page;
}
