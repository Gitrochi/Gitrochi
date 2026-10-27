import { useLayoutEffect, useRef, useState } from "react";
import type { HostAccount } from "@/entities/git";
import type { HubItem } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
/** Preload the exact project task before mounting Projects, including later item pages. */
export function useProjectNavigation(
  store: RepoStore,
  account: HostAccount | undefined,
  scope: "personal" | "repository",
  isCurrent: () => boolean,
  navigationContext: string,
  source: "local" | "remote" = "remote",
) {
  const [opening, setOpening] = useState(false),
    generation = useRef(0);
  useLayoutEffect(() => {
    generation.current++;
    setOpening(false);
    return () => {
      generation.current++;
    };
  }, [navigationContext]);
  const openProject = async (item: HubItem, rowID?: string) => {
    if ((source === "remote" && !account) || opening) return;
    const hub = store.hostingHub,
      id = account?.id,
      requestGeneration = generation.current;
    const current = () =>
      generation.current === requestGeneration &&
      isCurrent() &&
      store.destination === "home" &&
      (source === "local"
        ? hub.projectSource === "local"
        : hub.projectSource === "remote" && hub.account?.id === id) &&
      hub.section === "projects";
    setOpening(true);
    try {
      if (id) hub.selectedAccountID = id;
      hub.projectScope = scope;
      await hub.selectProjectSource(source);
      if (!current()) return;
      await hub.select(item);
      if (!current()) return;
      while (
        rowID &&
        hub.detail?.item.id === item.id &&
        !hub.detail.rows.some((row) => row.id === rowID) &&
        hub.detail.more
      ) {
        const cursor = hub.detailCursor;
        await hub.select(item, true);
        if (!current()) return;
        if (hub.error || hub.detailCursor === cursor) break;
      }
      if (!current()) return;
      const found =
        !!rowID &&
        hub.detail?.item.id === item.id &&
        hub.detail.rows.some((row) => row.id === rowID);
      if (rowID && !found && !hub.error)
        hub.error = t(
          "The task could not be found in this project. Refresh and try again.",
        );
      hub.requestProjectRow(found ? rowID! : null);
      store.navigate("projects");
    } finally {
      if (generation.current === requestGeneration) setOpening(false);
    }
  };
  return { opening, openProject };
}
