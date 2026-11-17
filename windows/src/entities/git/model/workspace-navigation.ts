/**
 * The pages of a repository window. Repository is the three-column screen (branches | graph | inspector);
 * the rest are full-width pages. (macOS: Core/WorkspaceNavigation.swift)
 */
export const workspaceDestinations = ["home", "repository", "compare", "rebase", "code", "pullRequests", "issues", "actions", "releases", "projects", "account", "flows"] as const;
export type WorkspaceDestination = (typeof workspaceDestinations)[number];
/** All known pages are available without changing optional background agent tracking. */
export const destinationEnabled = (_page: WorkspaceDestination) => true;
/** Pages whose tools need a repository; they are disabled until one is open. */
export const repositoryDestinations: ReadonlySet<WorkspaceDestination> = new Set<WorkspaceDestination>(["repository", "compare", "rebase", "code", "pullRequests", "actions", "flows"]);
/**
 * Whether the page can be opened: one that needs a repository is disabled until one is open, so a window without a
 * repository never shows it (docs/design.md › App shell, Sidebar). (macOS: isAvailable(hasRepository:))
 */
export const destinationAvailable = (page: WorkspaceDestination, hasRepository: boolean) => hasRepository || !repositoryDestinations.has(page);
/** The pages Ctrl+1–Ctrl+8 open, in the sidebar's order (docs/design.md › App shell, Sidebar). (macOS: shortcutDigit) */
const numberedDestinations: readonly WorkspaceDestination[] = ["repository", "compare", "rebase", "code", "pullRequests", "issues", "actions", "flows"];
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
/**
 * What Escape does on the repository screen; the first match wins. Whatever takes keys of its own keeps Escape (a
 * dialog, a menu or a popover, the terminal); then an open file history or blame closes, then an open diff; only
 * then the sidebar's Filter branches field, when the keys are in it and it has text, is cleared; and last, never from
 * a text field, Changes turns off and the graph is back. (macOS: RepositoryEscape)
 */
export type RepositoryEscape = "none" | "closeFileInspect" | "closeDiff" | "clearFilter" | "showGraph";
export function repositoryEscape(s: { overlay: boolean; terminal: boolean; typing: boolean; repositoryScreen: boolean; fileInspect: boolean; diff: boolean; filter: boolean; changes: boolean }): RepositoryEscape {
  if (s.overlay || s.terminal || !s.repositoryScreen) return "none";
  if (s.fileInspect) return "closeFileInspect";
  if (s.diff) return "closeDiff";
  if (s.filter) return "clearFilter";
  return s.changes && !s.typing ? "showGraph" : "none";
}
export function isWorkspaceDestination(value: unknown): value is WorkspaceDestination {
  return typeof value === "string" && (workspaceDestinations as readonly string[]).includes(value);
}
/** The page a repository opens on: the saved one when it is valid, otherwise the repository screen (Home without a repository). */
export function restoredDestination(saved: unknown, hasRepository: boolean): WorkspaceDestination {
  const page = isWorkspaceDestination(saved) ? saved : hasRepository ? "repository" : "home";
  return repositoryDestinations.has(page) && !hasRepository ? "home" : page;
}
