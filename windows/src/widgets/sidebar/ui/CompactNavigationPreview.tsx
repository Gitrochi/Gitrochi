import { useEffect, useRef } from "react";
import { createPortal } from "react-dom";
import type { WorkspaceDestination } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { Sidebar } from "./Sidebar";

/** Compact icons expose their existing lists without replacing the current workspace. */
export function CompactNavigationPreview({ page, title, trigger, focusFirst, store, openSettings, keepOpen, dismiss }: {
  page: WorkspaceDestination; title: string; trigger: HTMLElement; focusFirst: boolean; store: RepoStore;
  openSettings: () => void; keepOpen: () => void; dismiss: (restoreFocus?: boolean, delayed?: boolean) => void;
}) {
  const body = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (focusFirst) body.current?.querySelector<HTMLElement>("button, input, select, [tabindex='0']")?.focus();
  }, [page, focusFirst]);
  const rect = trigger.getBoundingClientRect();
  const height = Math.min(520, Math.max(120, window.innerHeight - 24));
  const top = Math.max(12, Math.min(rect.top, window.innerHeight - height - 12));
  const left = Math.max(8, Math.min(rect.right + 6, window.innerWidth - 336));
  const section = page === "repository" ? "repository" : page === "branches" ? "local" : page === "pullRequests" ? "prs" : page === "worktrees" ? "worktrees" : null;
  return createPortal(<div ref={body} id="workspace-navigation-preview" className="workspace-nav-preview" role="region" aria-label={title}
    style={{ top, left, maxHeight: height, ...(section ? { height } : {}) }}
    onMouseEnter={keepOpen} onMouseLeave={() => dismiss(false, true)} onFocus={keepOpen}
    onBlur={(event) => { if (!event.currentTarget.contains(event.relatedTarget as Node | null) && event.relatedTarget !== trigger) dismiss(); }}
    onKeyDown={(event) => { if (event.key === "Escape" || (event.key === "ArrowLeft" && !(event.target as HTMLElement).closest("input, textarea, select, [contenteditable]"))) { event.preventDefault(); event.stopPropagation(); dismiss(true); } }}>
    <header className="workspace-nav-preview-header"><strong>{title}</strong><Button size="small" onClick={() => { store.navigate(page); dismiss(); }}>{t("Open")}</Button></header>
    {section && <Sidebar store={store} openSettings={openSettings} flyout={section} />}
  </div>, document.body);
}
