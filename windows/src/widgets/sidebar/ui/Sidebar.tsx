import { Archive, CloudAlert, EyeOff, PanelLeftClose, Pin, ShieldCheck } from "lucide-react";
import { ChevronDown, Cloud, Folder, GitBranch, Search, Tag as TagIcon } from "@/shared/icons";
import { type ReactNode, useState } from "react";
import { localBranchMenu, remoteBranchMenu } from "@/features/git-menus";
import { agents, isActiveStatus } from "@/entities/agent";
import { type Branch, branchRemote, branchShort } from "@/entities/git";
import { branchPayload, type RepoStore } from "@/entities/repo";
import { samePath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { drag, useObserve } from "@/shared/lib";
import { HostedListEmpty, IconButton, Segmented, SharedStack, showContextMenu, StatusPill, tip } from "@/shared/ui";
import { branchFilterMatches, branchFilterQuery, filterFolders, folderCount, groupFolders, leaf } from "../lib/branch-filter";
import { AgentsPanel } from "./AgentsPanel";
import { Section, SectionFlyout } from "./Section";
import "./sidebar.css";

export type SidebarSectionID = "repository" | "local" | "remote" | "tags" | "stashes";

export function Sidebar({ store, flyout }: { store: RepoStore; flyout?: SidebarSectionID }) {
  useObserve(store);
  useObserve(settings);
  useObserve(agents);
  // CI moved to the Actions page; a saved "ci" mode falls through to the branch list (macOS: SidebarView.swift)
  const mode = settings.get<string>("sidebarMode", "list") === "agents" ? "agents" : "list";
  const active = agents.sessions.filter((s) => isActiveStatus(s.status) && store.worktrees.some((w) => samePath(w.path, s.path))).length;
  if (flyout) return <SectionFlyout.Provider value={true}><BranchList store={store} only={flyout === "repository" ? undefined : flyout} flyout /></SectionFlyout.Provider>;
  return (
    <>
      <div className="row side-modes">
        <div style={{ flex: 1, minWidth: 0 }}>
          <Segmented
            stretch
            value={mode}
            onChange={(v) => settings.set("sidebarMode", v)}
            options={[
              { value: "list", label: t("Branches") },
              { value: "agents", label: active ? t("Agents {0}", active) : t("Agents") },
            ]}
          />
        </div>
        <IconButton small icon={<PanelLeftClose size={15} />} tip={tip(t("Hide sidebar"), t("The sections stay at hand as a rail of icons; hover one to open it."))} onClick={() => settings.set("sidebarCollapsed", true)} />
      </div>
      {mode === "agents" ? <AgentsPanel store={store} /> : (
        <>
          <BranchFilterField store={store} />
          <BranchList store={store} />
        </>
      )}
    </>
  );
}

/**
 * The board's Filter branches field. Its text is the tab's view state on the store, so Escape can clear it through
 * the repository screen's one Escape order (app/lib/shortcuts.ts). (macOS: SidebarFilterField)
 */
function BranchFilterField({ store }: { store: RepoStore }) {
  return (
    <label className="side-filter">
      <Search size={13} />
      <input
        aria-label={t("Filter branches")}
        placeholder={t("Filter branches")}
        value={store.branchFilter}
        spellCheck={false}
        autoComplete="off"
        onChange={(e) => store.setBranchFilter(e.target.value)}
      />
    </label>
  );
}

function BranchList({ store, only, flyout = false }: { store: RepoStore; only?: string; flyout?: boolean }) {
  const show = (id: string) => !only || only === id;
  const [expanded, setExpanded] = useState<Set<string>>(() => {
    const h = store.headBranch;
    return new Set(h && h.includes("/") ? ["l:" + h.slice(0, h.indexOf("/"))] : []);
  });
  // the rail's flyouts have no field, so they list everything
  const query = flyout ? "" : branchFilterQuery(store.branchFilter);
  const filtering = query !== "";
  // while the filter is on, every folder left holds a match and stands open; the remembered state is not touched
  const isOpen = (id: string) => filtering || expanded.has(id);
  const toggle = (id: string) => {
    if (filtering) return;
    const s = new Set(expanded);
    if (s.has(id)) s.delete(id);
    else s.add(id);
    setExpanded(s);
  };
  const locals = filterFolders(groupFolders(store.localBranches, (b) => b.name, (b) => store.isPinned(b)), (b) => b.name, query);
  const byRemote = new Map<string, Branch[]>();
  for (const b of store.remoteBranches) {
    const r = branchRemote(b) ?? "";
    byRemote.set(r, [...(byRemote.get(r) ?? []), b]);
  }
  const remotes = [...byRemote.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([remote, list]) => ({ remote, groups: filterFolders(groupFolders(list, branchShort), (b) => b.name, query) }))
    .filter((r) => folderCount(r.groups) > 0);
  const tags = store.tags.filter((tag) => branchFilterMatches(tag.name, query));
  const localCount = folderCount(locals);
  // a section's own fold is left alone too: it opens for a match and goes back when the field is cleared
  const forced = filtering ? { open: true, onToggle: () => {} } : {};

  if (filtering && !localCount && !remotes.length && !tags.length) {
    return (
      <div className="side-scroll side-branches side-filter-empty">
        <HostedListEmpty
          icon={<Search size={24} />}
          title={t("No matching branches")}
          caption={t("No branch or tag name contains “{0}”.", store.branchFilter.trim())}
          action={{ label: t("Clear filter"), onClick: () => store.setBranchFilter("") }}
        />
      </div>
    );
  }

  // a folder is plain grey even when it holds the current branch: the branch's own marker says so
  const folder = (id: string, name: string, count: number, body: ReactNode, icon?: ReactNode) => (
    <div key={id} className="side-tree-group" data-tree-id={id}>
      <button type="button" className="side-row side-tree-row side-tree-toggle" aria-expanded={isOpen(id)} onClick={() => toggle(id)}>
        <span className="side-tree-disclosure" aria-hidden="true">
          <ChevronDown size={10} className="muted" style={{ transform: isOpen(id) ? undefined : "rotate(-90deg)" }} />
        </span>
        <span className="lead">{icon ?? <Folder size={13} />}</span>
        <span className="ellipsis grow side-tree-label">{name}</span>
        <StatusPill tone="neutral" className="side-count end">{count}</StatusPill>
      </button>
      {isOpen(id) && <div className="side-tree-children">{body}</div>}
    </div>
  );

  return (
    <SharedStack className="side-scroll side-branches">
      {show("local") && (!filtering || localCount > 0) && <Section id="local" title={t("Local branches")} count={localCount} {...forced}>
        {/* "Pin to top": pinned branches lead under their whole names, out of their folders */}
        {locals.pinned.map((b) => (
          <BranchRow key={b.name} store={store} branch={b} label={b.name} />
        ))}
        {locals.loose.map((b) => (
          <BranchRow key={b.name} store={store} branch={b} label={b.name} />
        ))}
        {locals.folders.map((f) =>
          folder(
            "l:" + f.name,
            f.name,
            f.branches.length,
            f.branches.map((b) => <BranchRow key={b.name} store={store} branch={b} label={leaf(b.name)} />),
          ),
        )}
      </Section>}

      {show("remote") && remotes.length > 0 && (
        // each remote's own row carries its count
        <Section id="remote" title={t("Remotes")} {...forced}>
          {remotes.map(({ remote, groups: g }) =>
            folder(
              "r:" + remote,
              remote,
              folderCount(g),
              <>
                {g.loose.map((b) => (
                  <BranchRow key={b.name} store={store} branch={b} label={branchShort(b)} />
                ))}
                {g.folders.map((f) =>
                  folder(
                    `r:${remote}/${f.name}`,
                    f.name,
                    f.branches.length,
                    f.branches.map((b) => <BranchRow key={b.name} store={store} branch={b} label={leaf(branchShort(b))} />),
                  ),
                )}
              </>,
              <Cloud size={13} />,
            ),
          )}
        </Section>
      )}

      {show("tags") && tags.length > 0 && (
        <Section id="tags" title={t("Tags")} count={tags.length} {...forced}>
          {tags.map((tag) => (
            <div
              key={tag.name}
              className="side-row side-tree-row"
              onClick={() => store.reveal(tag.target)}
              onContextMenu={(e) =>
                showContextMenu(e, [
                  { label: t("Go to this tag"), onClick: () => store.reveal(tag.target) },
                  { label: t("Push tag"), onClick: () => void store.pushTag(tag) },
                  ...(store.target ? [{ label: t("Open in Releases"), onClick: () => store.navigate("releases") }] : []),
                  "divider",
                  { label: t("Delete tag…"), danger: true, onClick: () => store.deleteTag(tag) },
                ])
              }
            >
              {/* the branch rows' disclosure column, so the names line up */}
              <span className="side-tree-disclosure" aria-hidden="true" />
              <span className="lead">
                <TagIcon size={13} />
              </span>
              <span className="ellipsis side-tree-label">{tag.name}</span>
            </div>
          ))}
        </Section>
      )}

      {/* no board draws stashes; the list stays because nothing else shows it. The field filters names, so it is hidden meanwhile */}
      {show("stashes") && !filtering && store.stashes.length > 0 && (
        <Section id="stashes" title={t("Stashes")} count={store.stashes.length}>
          {store.stashes.map((s) => (
            <div
              key={s.ref}
              className="side-row side-tree-row"
              style={{ alignItems: "flex-start" }}
              onClick={() => store.reveal(s.hash)}
              onContextMenu={(e) =>
                showContextMenu(e, [
                  { label: t("Apply"), onClick: () => void store.stashApply(s) },
                  { label: t("Pop"), onClick: () => void store.stashPop(s) },
                  "divider",
                  { label: t("Drop…"), danger: true, onClick: () => store.stashDrop(s) },
                ])
              }
            >
              <span className="side-tree-disclosure" aria-hidden="true" />
              <span className="lead" style={{ marginTop: 3 }}>
                <Archive size={13} />
              </span>
              <span className="col grow">
                <span className="ellipsis">{s.message}</span>
                <span className="side-sub">{s.ref}</span>
              </span>
            </div>
          ))}
        </Section>
      )}
    </SharedStack>
  );
}

/**
 * A branch row. After the name come only the marks whose state shows nowhere else (pinned, protected by gitch, hidden
 * from the graph, upstream gone), then ahead and behind. (macOS: BranchRow)
 */
function BranchRow({ store, branch: b, label }: { store: RepoStore; branch: Branch; label: string }) {
  const hidden = store.isHidden(b);
  return (
    <div
      className={`side-row side-tree-row ${b.isCurrent ? "current" : ""}`}
      draggable
      onDragStart={(e) => {
        e.dataTransfer.setData("text/plain", branchPayload + b.name);
        e.dataTransfer.effectAllowed = "move";
        drag.payload = branchPayload + b.name;
      }}
      onDragEnd={() => (drag.payload = null)}
      onClick={() => store.reveal(b.target)}
      onDoubleClick={() => void store.checkout(b)}
      onContextMenu={(e) => showContextMenu(e, b.isRemote ? remoteBranchMenu(store, b) : localBranchMenu(store, b))}
      data-tip={tip(b.name, t("Click: show in graph · Double-click: check out · Drag onto another branch in the graph: merge or rebase"))}
    >
      <span className="side-tree-disclosure" aria-hidden="true" />
      <span className="lead">{b.isCurrent ? <span className="side-current" role="img" aria-label={t("Current")}><span /></span> : <GitBranch size={13} />}</span>
      <span className="ellipsis grow side-tree-label" style={hidden ? { color: "var(--text-2)" } : undefined}>
        {label}
      </span>
      {store.isPinned(b) && (
        <span className="muted" data-tip={t("Pinned")} role="img" aria-label={t("Pinned")} style={{ display: "inline-flex" }}>
          <Pin size={11} />
        </span>
      )}
      {!b.isRemote && store.gitchProtected.has(b.name) && (
        <span className="muted" data-tip={t("Protected by gitch: no direct pushes, merge through a pull request")} style={{ display: "inline-flex" }}>
          <ShieldCheck size={12} />
        </span>
      )}
      {hidden && (
        // only a hidden branch carries the eye: it says so and shows the branch again (hiding is in the row's menu)
        <IconButton
          small
          icon={<EyeOff size={12} />}
          tip={t("Show in graph again")}
          onClick={(e) => {
            e.stopPropagation();
            void store.setHidden(b, false);
          }}
          onDoubleClick={(e) => e.stopPropagation()}
        />
      )}
      {b.upstreamGone && (
        <span style={{ color: "var(--orange)", display: "inline-flex" }} data-tip={t("The tracked remote branch was deleted")}>
          <CloudAlert size={13} />
        </span>
      )}
      {b.ahead > 0 && <span className="side-ab">↑{b.ahead}</span>}
      {b.behind > 0 && <span className="side-ab">↓{b.behind}</span>}
    </div>
  );
}
