import { workspace } from "@/entities/workspace";
import { type AppLaunch, ipc } from "@/shared/api";
import { samePath } from "@/shared/config";
import { t } from "@/shared/i18n";

/** App-layer coordination keeps workspace and repo entities independent of launch transport. */
export async function applyAppLaunch(route: AppLaunch) {
  await workspace.openInNewTab(route.repo);
  const store = workspace.tabs.find((tab) => samePath(tab.path, route.repo));
  if (!store) throw new Error(t("Couldn't open the requested repository."));
  workspace.select(store.id);
  if (route.commit) {
    store.closeFileInspect();
    store.select({ kind: "commit", sha: route.commit });
    store.reveal(route.commit);
    if (route.file) {
      // Commit details are loaded asynchronously by selection. Stop if the user selects elsewhere.
      const deadline = Date.now() + 10000;
      while (!store.detail && store.selection?.kind === "commit" && store.selection.sha === route.commit && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 40));
      }
      const change = store.detailFiles.find((c) => c.path === route.file || c.oldPath === route.file);
      if (store.selection?.kind === "commit" && store.selection.sha === route.commit && change) store.openDiff({ kind: "commit", sha: route.commit, change, parent: null });
    }
    return;
  }
  if (route.file) {
    const change = [...store.status.unstaged, ...store.status.staged].find((c) => c.path === route.file || c.oldPath === route.file);
    if (route.view === "diff" && change) store.openDiff({ kind: "working", change });
    else if (route.line) {
      store.openBlame(route.file, null, route.line);
    } else store.openFileHistory(route.file);
  } else if (route.view === "affected") {
    await store.openAffectedGraph();
  } else if (route.view === "precise") {
    await store.openStructureGraph("files", true);
  } else if (route.view && route.view !== "graph" && route.view !== "diff") {
    await store.openStructureGraph(route.view);
  } else {
    store.navigate("commits");
    store.closeFileInspect();
    store.closeDiff();
  }
}

export async function startAppLaunches() {
  let processing = Promise.resolve();
  const drain = () => {
    processing = processing.then(async () => {
      for (const item of await ipc.takeAppLaunches()) {
        try {
          if ("Err" in item) throw new Error(item.Err);
          await applyAppLaunch(item.Ok);
        } catch (error) {
          const store = workspace.active ?? workspace.newTab();
          store.fail(error instanceof Error ? t(error.message) : String(error));
        }
      }
    }).catch((error) => {
      const store = workspace.active ?? workspace.newTab();
      store.fail(error);
    });
    return processing;
  };
  // Register before draining so links delivered between restore and subscription stay queued.
  const unlisten = await ipc.onAppLaunch(() => void drain());
  await drain();
  window.addEventListener("beforeunload", unlisten, { once: true });
}
