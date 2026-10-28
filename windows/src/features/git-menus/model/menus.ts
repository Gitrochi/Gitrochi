import { type Branch, type Commit, isWIP, type RefLabel, short, wipWorktree } from "@/entities/git";
import { gitch, graphDiffRelations, graphRelations } from "@/entities/gitch";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { type MenuItem, tip } from "@/shared/ui";

/** 브랜치·태그 배지 우클릭 메뉴(그래프 배지와 커밋 메뉴에서 같이 쓴다) */
export function refMenu(store: RepoStore, ref: RefLabel): MenuItem[] {
  if (ref.kind === "local" || ref.kind === "remote") {
    const b = store.branchNamed(ref.name);
    if (!b) return [];
    return b.isRemote ? remoteBranchMenu(store, b) : localBranchMenu(store, b);
  }
  if (ref.kind === "tag") {
    const tag = store.tags.find((x) => x.name === ref.name);
    if (!tag) return [];
    return [
      { label: t("Go to this tag"), onClick: () => store.reveal(tag.target) },
      { label: t("Push tag"), onClick: () => void store.pushTag(tag) },
      { label: t("Copy name"), onClick: () => store.copy(tag.name) },
      "divider",
      { label: t("Delete tag…"), danger: true, onClick: () => store.deleteTag(tag) },
    ];
  }
  return [];
}

/** '이 브랜치를 다른 브랜치에 머지' 하위 메뉴(고른 브랜치를 체크아웃한 뒤 머지) */
function mergeIntoMenu(store: RepoStore, source: string): MenuItem[] {
  const targets = store.mergeTargets(source);
  if (!targets.length) return [];
  return [
    {
      label: t("Merge '{0}' into another branch", source),
      submenu: targets.map((branch): MenuItem => ({ label: branch.isCurrent ? t("{0} (current)", branch.name) : branch.name, onClick: () => void store.mergeBranch(source, branch.name) })),
    },
  ];
}

export function localBranchMenu(store: RepoStore, b: Branch): MenuItem[] {
  const current = store.headBranch;
  const w = store.worktreeUsing(b.name);
  const items: MenuItem[] = [{ label: t("Check out"), disabled: b.isCurrent, onClick: () => void store.checkout(b) }];
  if (current && !b.isCurrent) {
    items.push(
      { label: t("Merge '{0}' into '{1}'", b.name, current), onClick: () => void store.merge(b.name) },
      { label: t("Rebase '{0}' onto '{1}'", current, b.name), onClick: () => void store.rebase(b.name) },
    );
  }
  items.push(...mergeIntoMenu(store, b.name));
  items.push(
    "divider",
    { label: t("New branch from here…"), onClick: () => store.requestNewBranch(b.target, b.name) },
    {
      label: t("Check out in a new worktree…"),
      disabled: b.isCurrent || !!w,
      onClick: () => {
        store.sheet = { kind: "addWorktree", branch: b.name, start: null };
        store.changed();
      },
    },
  );
  if (w) {
    items.push(
      { label: t("Open this branch's worktree"), onClick: () => void store.switchWorktree(w.path) },
      { label: t("Run an agent in a worktree"), onClick: () => void store.startAgent(w.path) },
    );
  }
  items.push(
    { label: t("Push"), onClick: () => void store.pushBranch(b) },
    { label: t("Copy name"), onClick: () => store.copy(b.name) },
  );
  if (store.gitchStatus) {
    const on = store.gitchProtected.has(b.name);
    items.push({ label: on ? t("Allow direct push (gitch)") : t("Protect from direct push (gitch)"), onClick: () => void store.setGitchProtected(b.name, !on) });
  }
  items.push(
    "divider",
    { label: store.isPinned(b) ? t("Unpin") : t("Pin to top"), onClick: () => store.setPinned(b, !store.isPinned(b)) },
    {
      label: store.isHidden(b) ? t("Show in graph again") : t("Hide from graph"),
      disabled: b.isCurrent && !store.isHidden(b),
      onClick: () => void store.setHidden(b, !store.isHidden(b)),
    },
    "divider",
    { label: t("Delete…"), danger: true, disabled: b.isCurrent, onClick: () => store.confirmDelete(b) },
    { label: t("Force delete…"), danger: true, disabled: b.isCurrent, onClick: () => store.confirmForceDelete(b) },
  );
  return items;
}

export function remoteBranchMenu(store: RepoStore, b: Branch): MenuItem[] {
  const current = store.headBranch;
  const items: MenuItem[] = [{ label: t("Check out (local tracking branch)"), onClick: () => void store.checkout(b) }];
  if (current) {
    items.push(
      { label: t("Merge '{0}' into '{1}'", b.name, current), onClick: () => void store.merge(b.name) },
      { label: t("Rebase '{0}' onto '{1}'", current, b.name), onClick: () => void store.rebase(b.name) },
    );
  }
  items.push(...mergeIntoMenu(store, b.name));
  items.push(
    "divider",
    { label: t("New branch from here…"), onClick: () => store.requestNewBranch(b.target, b.name) },
    { label: t("Copy name"), onClick: () => store.copy(b.name) },
    { label: store.isHidden(b) ? t("Show in graph again") : t("Hide from graph"), onClick: () => void store.setHidden(b, !store.isHidden(b)) },
    "divider",
    { label: t("Delete from remote…"), danger: true, onClick: () => store.confirmDelete(b) },
  );
  return items;
}

/** 그래프 행 우클릭 메뉴 */
export function commitMenu(store: RepoStore, c: Commit): MenuItem[] {
  const sheet = (s: RepoStore["sheet"]) => {
    store.sheet = s;
    store.changed();
  };
  const worktree = wipWorktree(c);
  if (worktree !== null) {
    return [
      { label: t("Open worktree"), onClick: () => void store.switchWorktree(worktree) },
      { label: t("Open in new tab"), onClick: () => void store.openOrReport(worktree) },
      { label: t("Show in Explorer"), onClick: () => void ipc.reveal(worktree) },
    ];
  }
  if (isWIP(c)) {
    return [
      { label: t("Stage all"), onClick: () => void store.stageAll() },
      { label: t("Stash…"), onClick: () => sheet({ kind: "stash" }) },
      "divider",
      { label: t("Discard all changes…"), danger: true, onClick: () => store.confirmDiscardAll() },
    ];
  }
  const items: MenuItem[] = [];
  const branches = (store.refsByCommit.get(c.id) ?? []).filter((r) => r.kind === "local" || r.kind === "remote");
  for (const r of branches) items.push({ label: t("Branch '{0}'", r.name), submenu: refMenu(store, r) });
  if (branches.length) items.push("divider");
  const current = store.headBranch;
  if (current && c.id !== store.headHash) {
    items.push(
      { label: t("Merge this commit into '{0}'", current), onClick: () => void store.merge(c.id) },
      { label: t("Rebase '{0}' onto this commit", current), onClick: () => void store.rebase(c.id) },
      "divider",
    );
  }
  if (current) {
    items.push({ label: t("Clean up commits from here (squash, reorder, reword)…"), disabled: store.repoState !== "clean", onClick: () => void store.startInteractiveRebase(c.id) }, "divider");
  }
  items.push(
    { label: t("Compare with HEAD…"), onClick: () => store.openRevisionComparison(c.id, "HEAD") },
    { label: t("New branch from here…"), onClick: () => store.requestNewBranch(c.id, short(c.id)) },
    { label: t("Tag here…"), onClick: () => sheet({ kind: "tag", sha: c.id }) },
    { label: t("Create worktree from here…"), onClick: () => sheet({ kind: "addWorktree", branch: null, start: c.id }) },
    "divider",
    { label: t("Check out this commit (detached HEAD)"), onClick: () => void store.checkoutDetached(c.id) },
    { label: t("Cherry-pick"), disabled: c.id === store.headHash, onClick: () => void store.cherryPick(c.id) },
    { label: t("Revert (create a reverting commit)"), onClick: () => void store.revert(c.id) },
  );
  if (store.headBranch) {
    items.push({
      label: t("Reset current branch to here"),
      submenu: [
        { label: t("Soft — keep changes staged"), onClick: () => store.reset(c.id, "soft") },
        { label: t("Mixed — keep changes in the working tree"), onClick: () => store.reset(c.id, "mixed") },
        { label: t("Hard — discard changes too…"), danger: true, onClick: () => store.reset(c.id, "hard") },
      ],
    });
  }
  items.push("divider", { label: t("Copy SHA"), onClick: () => store.copy(c.id) }, { label: t("Copy message"), onClick: () => store.copy(c.subject) });
  return items;
}

/**
 * 저장소 메뉴(툴바 · ≡ 메뉴)의 gitch graph 항목들 — 앱에 든 gitch 로 html 을 만들어 기본 브라우저로 연다.
 * 「Structure graph」(관계를 고름), 「Dependencies changed on this branch」(gitch graph diff), 「Check dependency rules…」(gitch graph check, 결과 창).
 * gitch 계정이 없어도 되는 기능이라, 계정을 만들어 두었을 때만 보이는 커밋 칸 위 ⋯ 메뉴가 아니라 저장소 메뉴에 둔다.
 */
export function structureGraphMenus(store: RepoStore | null): MenuItem[] {
  const summary = t("Explore this repository's imports, modules, co-changing files and folders in the graph workspace.");
  const diffSummary = t("Compare working-tree dependencies with the branch's common ancestor in the graph workspace.");
  const checkSummary = t("Checks the dependencies against the rules in .gitch/graph.rules (gitch graph check) and lists what breaks them.");
  const graph = t("Structure graph");
  const diff = t("Dependencies changed on this branch");
  const check = t("Check dependency rules…");
  // 앱에 든 gitch 를 아직 안 봤으면(보통은 저장소를 열 때 봐 둔다) 켜 두고, 누르면 그릴 때 다시 본다
  const reason = gitch.graphReason;
  if (reason === undefined) void gitch.checkGraph();
  if (!store?.path || reason)
    return [
      { label: graph, disabled: true, tip: tip(graph, reason ?? summary) },
      { label: diff, disabled: true, tip: tip(diff, reason ?? diffSummary) },
      { label: check, disabled: true, tip: tip(check, reason ?? checkSummary) },
    ];
  // 페이지는 한 번에 하나만 만든다(그동안 툴바에 진행 표시)
  const working = store.graphJob != null;
  return [
    {
      label: graph,
      tip: tip(graph, store.graphProgress ?? summary),
      submenu: [
        ...graphRelations().map((r) => ({ label: r.title, tip: tip(r.title, r.detail), disabled: working, onClick: () => void store.openStructureGraph(r.id) })),
        "divider",
        { label: t("Precise file references"), tip: t("Uses an existing index.scip or .gitch/index.scip for symbol references. Shows the analysis coverage when no current index is available."), disabled: working, onClick: () => void store.openStructureGraph("files", true) },
        { label: t("Files affected by changes"), tip: t("Shows changed files and the files that depend on them, including uncommitted changes."), disabled: working, onClick: () => void store.openAffectedGraph() },
      ],
    },
    {
      label: diff,
      tip: tip(diff, store.graphProgress ?? diffSummary),
      submenu: [
        ...graphDiffRelations().map((r): MenuItem => ({ label: r.title, tip: tip(r.title, r.detail), disabled: working, onClick: () => void store.openGraphDiff(r.id) })),
        "divider",
        {
          label: t("Compare with…"),
          tip: tip(t("Compare with…"), t("Pick a branch or tag. Gitrochi compares with where this branch split off from it.")),
          disabled: working,
          onClick: () => store.openSheet({ kind: "graphDiff" }),
        },
      ],
    },
    { label: check, tip: tip(check, checkSummary), onClick: () => void store.checkGraphRules() },
  ];
}
