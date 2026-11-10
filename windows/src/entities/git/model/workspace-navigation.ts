/**
 * The pages of a repository window. Repository is the three-column screen (branches | graph | inspector);
 * the rest are full-width pages. (macOS: Core/WorkspaceNavigation.swift)
 */
export const workspaceDestinations = ["home", "repository", "compare", "rebase", "code", "pullRequests", "issues", "actions", "releases", "projects", "account", "flows"] as const;
/** Kept separate for compatibility with existing destination lists. Ledger navigation is always available. */
export const previewDestinations = ["ledger"] as const;
export type WorkspaceDestination = (typeof workspaceDestinations)[number] | (typeof previewDestinations)[number];
/** All known pages are available without changing optional background agent tracking. */
export const destinationEnabled = (_page: WorkspaceDestination) => true;
/** Pages whose tools need a repository; navigation shows a chooser until one is open. */
export const repositoryDestinations: ReadonlySet<WorkspaceDestination> = new Set<WorkspaceDestination>(["repository", "compare", "rebase", "code", "pullRequests", "actions", "flows"]);
/** The pages Ctrl+1–Ctrl+9 open, in the sidebar's order (docs/design.md › App shell, Sidebar). (macOS: shortcutDigit) */
const numberedDestinations: readonly WorkspaceDestination[] = ["repository", "compare", "rebase", "code", "pullRequests", "issues", "actions", "flows", "ledger"];
/** The page's shortcut as menus and the sidebar show it; Home is Ctrl+Shift+H, Releases, Projects and Account have none */
export const destinationShortcut = (page: WorkspaceDestination): string | null => {
  if (page === "home") return "Ctrl+Shift+H";
  const digit = numberedDestinations.indexOf(page) + 1;
  return digit > 0 ? `Ctrl+${digit}` : null;
};
/** The page a Ctrl+digit shortcut opens */
export const destinationForDigit = (digit: number): WorkspaceDestination | null => numberedDestinations[digit - 1] ?? null;
/** Pages the repository screen links to (request and issue rows, a commit's CI badge, the tags); opened from there, they offer the way back (macOS: returnsToRepository) */
export const returnsToRepository: ReadonlySet<WorkspaceDestination> = new Set<WorkspaceDestination>(["pullRequests", "issues", "actions", "releases"]);
/** The toolbar items a window shows (docs/design.md › App shell). (macOS: ToolbarSet) */
export type ToolbarSet = "repository" | "page" | "noRepository";
export const toolbarSet = (destination: WorkspaceDestination, hasRepository: boolean): ToolbarSet => (!hasRepository ? "noRepository" : destination === "repository" ? "repository" : "page");
/** The one sync action drawn prominent: Push with only commits to push, Pull when a fast-forward is possible. (macOS: RecommendedSync) */
export function recommendedSync(ahead: number, behind: number, hasUpstream: boolean): "push" | "pull" | "none" {
  if (!hasUpstream) return "none";
  if (ahead > 0 && behind === 0) return "push";
  if (behind > 0 && ahead === 0) return "pull";
  return "none";
}
export function isWorkspaceDestination(value: unknown): value is WorkspaceDestination {
  if (typeof value !== "string") return false;
  if ((workspaceDestinations as readonly string[]).includes(value)) return true;
  return (previewDestinations as readonly string[]).includes(value) && destinationEnabled(value as WorkspaceDestination);
}
/** The page a repository opens on: the saved one when it is valid, otherwise the repository screen (Home without a repository). */
export function restoredDestination(saved: unknown, hasRepository: boolean): WorkspaceDestination {
  const page = isWorkspaceDestination(saved) ? saved : hasRepository ? "repository" : "home";
  return repositoryDestinations.has(page) && !hasRepository ? "home" : page;
}
