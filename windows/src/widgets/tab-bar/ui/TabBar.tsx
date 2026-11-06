import { Menu, Settings } from "lucide-react";
import { Plus, X } from "@/shared/icons";
import { structureGraphMenus } from "@/features/git-menus";
import type { RepoStore } from "@/entities/repo";
import { workspace } from "@/entities/workspace";
import { ipc } from "@/shared/api";
import { env, keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { updater } from "@/shared/platform";
import { IconButton, type MenuItem, showContextMenu, showMenuBelow, Spinner, tip } from "@/shared/ui";
import "./tab-bar.css";

/** 맨 위 탭 줄: 탭, 새 탭, 설정, 메뉴 */
export function TabBar({ openSettings }: { openSettings: () => void }) {
  useObserve(workspace);
  return (
    <div className="tabbar">
      {workspace.tabs.map((tab) => (
        <Tab key={tab.id} store={tab} on={tab === workspace.active} />
      ))}
      <div className="tabbar-end">
        <IconButton icon={<Plus size={16} />} tip={tip(t("New tab"), t("Opens another repository in a new tab."), "Ctrl+T")} onClick={() => workspace.newTab()} />
        <span className="spacer" />
      </div>
      <span className="spacer" />
      <div className="tabbar-end">
        <IconButton icon={<Settings size={15} />} tip={tip(t("Settings"), t("Connect GitHub and GitLab accounts and Claude"), "Ctrl+,")} onClick={openSettings} />
        <IconButton
          icon={<Menu size={16} />}
          tip={t("Menu")}
          onClick={(e) => {
            const s = workspace.active;
            showMenuBelow(e.currentTarget, [
              { label: t("New tab"), shortcut: "Ctrl+T", onClick: () => workspace.newTab() },
              { label: t("Open repository…"), shortcut: "Ctrl+O", onClick: () => void (s?.path ? workspace.newTab() : s)?.pickAndOpen() },
              { label: t("Clone repository…"), shortcut: "Ctrl+Shift+O", onClick: () => s?.openSheet({ kind: "clone" }) },
              { label: t("Create new repository…"), onClick: () => void s?.pickAndInit() },
              "divider",
              { label: t("Refresh"), shortcut: "F5", disabled: !s?.path, onClick: () => void s?.reload() },
              { label: t("Search commits"), shortcut: "Ctrl+F", disabled: !s?.path, onClick: () => s?.requestSearchFocus() },
              { label: t("Show/hide terminal"), shortcut: "Ctrl+`", disabled: !s?.path, onClick: () => s?.toggleTerminal() },
              ...structureGraphMenus(s ?? null),
              "divider",
              { label: t("Settings…"), shortcut: "Ctrl+,", onClick: openSettings },
              { label: updater.state === "available" ? t("Install update {0}…", updater.info?.version) : t("Check for updates…"), onClick: () => void updater.check(true) },
              { label: `Gitrochi ${env.version} · GitHub`, onClick: () => void ipc.openUrl("https://github.com/Gitrochi/Gitrochi") },
            ]);
          }}
        />
      </div>
    </div>
  );
}

function Tab({ store, on }: { store: RepoStore; on: boolean }) {
  useObserve(store);
  return (
    <div
      className={`tab ${on ? "on" : ""}`}
      onMouseDown={(e) => {
        if (e.button === 1) {
          e.preventDefault();
          workspace.closeTab(store.id);
        } else if (e.button === 0) workspace.select(store.id);
      }}
      onContextMenu={(e) => showContextMenu(e, tabMenu(store))}
      data-tip={store.path ? store.path : t("New tab")}
    >
      {(store.loading || store.busy) && <Spinner size={11} />}
      <span className="ellipsis grow" style={{ fontWeight: on ? 600 : 400 }}>
        {store.path ? store.name : store.loading ? store.loading.title : t("New tab")}
      </span>
      <IconButton
        small
        className="close"
        icon={<X size={12} />}
        tip={keyLabel(t("Close tab (Ctrl+W)"))}
        onMouseDown={(e) => e.stopPropagation()}
        onClick={() => workspace.closeTab(store.id)}
      />
    </div>
  );
}

/** 탭 우클릭 메뉴. 닫히는 탭에서 터미널·에이전트 세션이 돌고 있으면 한 번 묻는다(닫으면 함께 끝난다). */
function tabMenu(store: RepoStore): MenuItem[] {
  const others = workspace.tabs.filter((tab) => tab !== store);
  const closing = (tabs: RepoStore[], action: () => void, what: string) => () => {
    const running = tabs.reduce((n, tab) => n + tab.terminals.filter((x) => x.running).length, 0);
    if (!running) return action();
    workspace.select(store.id);
    store.ask({
      title: t("Close {0}?", what),
      message: t("{0} running terminal and agent sessions will end too.", running),
      actionTitle: t("Close"),
      action,
    });
  };
  return [
    { label: t("Close this tab"), shortcut: store === workspace.active ? "Ctrl+W" : undefined, onClick: closing([store], () => workspace.closeTab(store.id), t("This tab")) },
    { label: t("Close other tabs"), disabled: !others.length, onClick: closing(others, () => workspace.closeOthers(store.id), t("{0} other tabs", others.length)) },
    { label: t("Close all tabs"), onClick: closing(workspace.tabs, () => workspace.closeAll(), t("All {0} tabs", workspace.tabs.length)) },
  ];
}
