import { scheduledRuns } from "@/entities/ci";
import { workspace } from "@/entities/workspace";
import { samePath } from "@/shared/config";

/**
 * Starts Actions runs scheduled for later while the app is open, whichever repositories are, and shows a started run
 * in its repository when that is open; a dispatched workflow takes a few seconds to appear in the list.
 * (macOS: AppDelegate › ScheduledRunStore.start)
 */
export function startScheduledRuns() {
  scheduledRuns.onStarted = (run) => {
    for (const tab of workspace.tabs) {
      if (samePath(tab.path, run.repoPath)) setTimeout(() => void tab.ci.load(true), run.provider === "github" ? 4000 : 700);
    }
  };
  return scheduledRuns.start();
}
