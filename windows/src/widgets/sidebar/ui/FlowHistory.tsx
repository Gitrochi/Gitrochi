import { TriangleAlert } from "lucide-react";
import { useState } from "react";
import { type FlowRunRow, flowTone, formatDuration, runRowPresentationState } from "@/entities/flow";
import { ListFilter, Search } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { listWhen } from "@/shared/lib";
import { Button } from "@/shared/ui";
import { FlowStateIcon, stateTitle } from "./FlowState";
import "./flow-history.css";

const FILTER_STATES = ["RUNNING", "SUCCEEDED", "FAILED", "CANCELLED", "ROLLED_BACK", "ROLLBACK_FAILED", "REJECTED", "INTERRUPTED"];

/**
 * The History tab: the selected flow's runs, newest first, one line each (how it ended, how long it took, when).
 * A row opens the run. (macOS: FlowHistoryView)
 */
export function FlowHistory({ runs, onOpen }: { runs: FlowRunRow[]; onOpen: (runId: string) => void }) {
  const [filter, setFilter] = useState("");
  const [state, setState] = useState("all");
  const query = filter.trim().toLowerCase();
  const shown = runs.filter((run) => {
    const matchesText = !query || run.runId.toLowerCase().includes(query) || stateTitle(runRowPresentationState(run)).toLowerCase().includes(query);
    const matchesState = state === "all" || (state === "RUNNING" ? !!run.running : runRowPresentationState(run) === state);
    return matchesText && matchesState;
  });
  if (!runs.length) {
    return (
      <div className="flow-history" data-flow-history>
        <div className="flow-empty"><strong>{t("No runs yet")}</strong><span>{t("Run a flow to see its steps, output and results here.")}</span></div>
      </div>
    );
  }
  return (
    <div className="flow-history" data-flow-history>
      <div className="flow-history-filters">
        <label className="flow-history-search"><Search size={13} /><input aria-label={t("Filter runs")} placeholder={t("Filter runs")} value={filter} onChange={(event) => setFilter(event.target.value)} /></label>
        <label className="flow-history-status"><ListFilter size={13} />
          <select aria-label={t("Run status")} value={state} onChange={(event) => setState(event.target.value)}>
            <option value="all">{t("All statuses")}</option>
            {FILTER_STATES.map((value) => <option key={value} value={value}>{stateTitle(value)}</option>)}
          </select>
        </label>
      </div>
      {shown.length ? (
        <div className="flow-history-list">{shown.map((run) => <HistoryRow key={run.runId} run={run} onOpen={() => onOpen(run.runId)} />)}</div>
      ) : (
        <div className="flow-empty"><strong>{t("No matching runs")}</strong><Button onClick={() => { setFilter(""); setState("all"); }}>{t("Clear filters")}</Button></div>
      )}
    </div>
  );
}

function HistoryRow({ run, onOpen }: { run: FlowRunRow; onOpen: () => void }) {
  const state = runRowPresentationState(run);
  return (
    <button type="button" className="flow-history-row status-tone" data-tone={flowTone(state)} data-flow-run={run.runId} onClick={onOpen}>
      <FlowStateIcon state={state} size={14} />
      <span className="flow-history-run mono">{run.runId}</span>
      <span className="flow-history-verdict">
        {stateTitle(state)}
        {run.signed === false && !run.running && <TriangleAlert size={12} color="var(--orange)" data-tip={t("This record isn't signed by the engine, so gates don't trust it")} />}
      </span>
      <span className="flow-history-duration mono">{run.durationMs != null ? formatDuration(run.durationMs) : ""}</span>
      <span className="flow-history-time">{run.startedAt ? <time dateTime={run.startedAt}>{listWhen(Date.parse(run.startedAt) / 1000)}</time> : ""}</span>
    </button>
  );
}
