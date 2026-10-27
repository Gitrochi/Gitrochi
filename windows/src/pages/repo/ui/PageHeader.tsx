import { ChevronLeft } from "lucide-react";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { destinationIcons, destinationTitle } from "@/widgets/sidebar";

/**
 * The title row every workspace page shares; a Pull requests or Issues page reached from the repository screen also
 * offers the way back. (macOS: PageHeader in WorkspaceDestinationContent.swift)
 */
export function PageHeader({ store }: { store: RepoStore }) {
  useObserve(store);
  const page = store.destination;
  const Icon = destinationIcons[page];
  const back = store.cameFromRepository && (page === "pullRequests" || page === "issues" || page === "releases");
  return (
    <header className="page-header">
      {back && (
        <>
          <button type="button" className="page-header-back" aria-label={t("Back to the repository screen")} data-tip={t("Back to the repository screen")} onClick={() => store.navigate("repository")}>
            <ChevronLeft size={15} />
            {t("Repository")}
          </button>
          <span className="page-header-divider" />
        </>
      )}
      <Icon size={18} className="muted" />
      <h1>{destinationTitle(page, store.target?.provider === "gitlab")}</h1>
    </header>
  );
}
