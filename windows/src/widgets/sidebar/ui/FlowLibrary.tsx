import { type RefObject, useRef } from "react";
import { type FlowItem, type FlowRunRow, runRowPresentationState } from "@/entities/flow";
import { Plus, Search, X } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { listWhen } from "@/shared/lib";
import { Button } from "@/shared/ui";
import { FlowStateIcon } from "./FlowState";
import "./flow-library.css";

/**
 * The list column: every flow in the repository with how its latest run ended and when. Choosing one fills the
 * rest of the workspace. (macOS: FlowLibraryView)
 */
export function FlowLibrary({ flows, runs, selected, search, onSearch, onChoose, onCreate }: {
  flows: FlowItem[];
  runs: FlowRunRow[];
  selected: string | null;
  search: string;
  onSearch: (value: string) => void;
  onChoose: (name: string) => void;
  /** Left out when there is no engine to create a flow with */
  onCreate?: () => void;
}) {
  const input = useRef<HTMLInputElement>(null);
  const query = search.trim().toLocaleLowerCase();
  const visible = flows.filter((flow) => `${flow.name} ${flow.description ?? ""}`.toLocaleLowerCase().includes(query));
  const clear = () => { onSearch(""); input.current?.focus(); };
  return (
    <aside className="flow-library" aria-label={t("Flows")}>
      <div className="flow-library-tools">
        <FlowSearch input={input} value={search} onChange={onSearch} onClear={clear} />
        {onCreate && <Button className="flow-create-action" onClick={onCreate}><Plus size={13} />{t("New flow…")}</Button>}
      </div>
      <div className="flow-library-list">
        {visible.map((flow) => (
          <FlowChoice key={flow.name} flow={flow} latest={runs.find((run) => run.flow === flow.name)} selected={flow.name === selected} onChoose={() => onChoose(flow.name)} />
        ))}
        {query && !visible.length && (
          <div className="flow-library-empty" role="status">
            <Search size={24} />
            <span>{t("No matching flows")}</span>
            <Button size="small" onClick={clear}>{t("Clear search")}</Button>
          </div>
        )}
      </div>
    </aside>
  );
}

function FlowSearch({ input, value, onChange, onClear }: { input: RefObject<HTMLInputElement>; value: string; onChange: (value: string) => void; onClear: () => void }) {
  return (
    <div className="flow-library-search">
      <Search size={13} aria-hidden="true" />
      <input ref={input} type="search" aria-label={t("Find flows")} placeholder={t("Find flows")} value={value} onChange={(event) => onChange(event.target.value)} />
      {value && <button type="button" aria-label={t("Clear search")} data-tip={t("Clear search")} onClick={onClear}><X size={13} /></button>}
    </div>
  );
}

/** One flow: its name, how the latest run ended, when that was, and what the flow is for */
function FlowChoice({ flow, latest, selected, onChoose }: { flow: FlowItem; latest?: FlowRunRow; selected: boolean; onChoose: () => void }) {
  const state = latest ? runRowPresentationState(latest) : flow.last?.state ?? null;
  const at = latest?.startedAt ?? flow.last?.finishedAt ?? null;
  const when = at ? listWhen(Date.parse(at) / 1000) : t("Not run yet");
  return (
    <button type="button" className={`flow-choice ${selected ? "selected" : ""}`} aria-pressed={selected} data-flow-choice={flow.name} onClick={onChoose}>
      <span className="flow-choice-heading">
        <strong>{flow.name}</strong>
        {state && <FlowStateIcon state={state} size={12} />}
        <span className="flow-choice-when">{when}</span>
      </span>
      {flow.description && <span className="flow-choice-description">{flow.description}</span>}
    </button>
  );
}
