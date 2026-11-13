import { TriangleAlert } from "lucide-react";
import { type ReactNode, useState } from "react";
import { type FlowStepView, flowLogTail, flowSkipCause, flowStepSummary, flowTone, formatDuration, type RunNode } from "@/entities/flow";
import { t } from "@/shared/i18n";
import { Button, StatusPill } from "@/shared/ui";
import { FlowStateIcon, flowStepKindTitle, stateTitle } from "./FlowState";
import "./flow-step-details.css";

/** How many lines of output the step details show before "Show earlier lines" */
const OUTPUT_LINES = 8;

type Json = Record<string, unknown>;
const list = (value: unknown) => (Array.isArray(value) ? (value as Json[]) : []);
const text = (value: unknown) => (typeof value === "string" ? value : null);

/**
 * The right column: everything about the selected step in reading order. First how it did in the latest run and
 * why, then what it runs, then what it needs and where it is written. (macOS: FlowStepDetailsView)
 */
export function FlowStepDetails({ step, steps, run, record, onEdit, onOpenRun }: {
  step?: FlowStepView;
  /** Every step of the flow, to name the step a skipped one was waiting for */
  steps: FlowStepView[];
  /** The step in the latest run: its reason and the end of its output */
  run?: RunNode;
  /** The latest run's record (run.json), which holds the engine's verdicts */
  record?: Json;
  onEdit: () => void;
  /** Left out when no run has this step */
  onOpenRun?: () => void;
}) {
  if (!step) {
    return (
      <aside className="flow-inspector" aria-label={t("Step details")}>
        <div className="flow-inspector-empty">{t("Choose a step to inspect its script and dependencies.")}</div>
      </aside>
    );
  }
  const recorded = list(record?.nodes).find((node) => node.id === step.id);
  const summary = flowStepSummary(step);
  return (
    <aside className="flow-inspector" aria-label={t("Step details")}>
      <header className="flow-inspector-header">
        <strong className="mono">{step.id}</strong>
        <StatusPill tone="neutral">{flowStepKindTitle(step.block)}</StatusPill>
        <span className="spacer" />
        <button type="button" className="flow-text-button" onClick={onEdit}>{t("Edit step…")}</button>
      </header>
      <div className="flow-inspector-body">
        {summary && <p className="flow-step-description">{summary}</p>}
        {step.state && <StepOutcome step={step} steps={steps} run={run} failure={recorded?.failure as Json | undefined} onOpenRun={onOpenRun} />}
        <StepVerdicts verdicts={list(recorded?.verdicts)} />
        {run && run.tail.length > 0 && <StepOutput key={step.id} lines={run.tail} />}
        {step.run && <Script title={t("Command")} script={step.run} />}
        {step.undo && <Script title={t("Undo script")} script={step.undo} />}
        <dl className="flow-step-facts">
          <Fact name={t("Needs")}>
            {step.needs.length ? step.needs.map((id) => <span key={id} className="flow-dependency-chip mono">{id}</span>) : <span className="muted">{t("None")}</span>}
          </Fact>
          <Fact name={t("Runs on")}>{!step.executor || step.executor === "local" ? t("This computer") : <span className="mono">{step.executor}</span>}</Fact>
          {step.src && <Fact name={t("Source")}><span className="mono flow-step-source">{step.src}</span></Fact>}
        </dl>
        {step.reason?.message && <p className="flow-step-note">{step.reason.message}</p>}
        {step.outward && <p className="flow-step-warning"><TriangleAlert size={12} />{t("Acts outside this computer")}</p>}
      </div>
    </aside>
  );
}

/** The outcome in one line ("Failed after 2m 10s"), the engine's reason below it, and the way into the run */
function StepOutcome({ step, steps, run, failure, onOpenRun }: { step: FlowStepView; steps: FlowStepView[]; run?: RunNode; failure?: Json; onOpenRun?: () => void }) {
  const tone = flowTone(step.state);
  const took = step.durationMs != null ? formatDuration(step.durationMs) : null;
  const cause = flowSkipCause(step, steps);
  const line = tone === "failed" && took ? t("Failed after {0}", took)
    : step.state === "PASSED" && took ? t("Passed in {0}", took)
    : cause ? t("Skipped because {0} did not pass", cause)
    : stateTitle(step.state);
  const reason = text(failure?.description) ?? run?.reason ?? null;
  return (
    <section className="flow-step-outcome status-tone" data-tone={tone} role="status">
      <span className="flow-step-outcome-line"><FlowStateIcon state={step.state} size={14} /><span>{line}</span></span>
      {reason && <span className="flow-step-outcome-reason selectable">{reason}</span>}
      {text(failure?.action) && <span className="flow-step-outcome-reason">{text(failure?.action)}</span>}
      {onOpenRun && <div className="flow-step-outcome-actions"><Button onClick={onOpenRun}>{t("Open run…")}</Button></div>}
    </section>
  );
}

/** The engine's own checks for this step, exactly as it judged them */
function StepVerdicts({ verdicts }: { verdicts: Json[] }) {
  if (!verdicts.length) return null;
  return (
    <section className="flow-step-section">
      <h4>{t("Verdicts")}</h4>
      {verdicts.map((verdict, index) => (
        <div key={index} className="flow-verdict">
          <FlowStateIcon state={verdict.result === "PASS" ? "PASSED" : "FAILED"} size={12} />
          <span className="mono flow-verdict-rule">{text(verdict.rule)}</span>
          <span className="flow-verdict-title">{text(verdict.title)}</span>
          {text(verdict.observed) && <span className="mono flow-verdict-observed">{text(verdict.observed)}</span>}
        </div>
      ))}
    </section>
  );
}

/** The end of the step's output; earlier lines stay folded until asked for */
function StepOutput({ lines }: { lines: string[] }) {
  const [all, setAll] = useState(false);
  const tail = flowLogTail(lines, all ? lines.length : OUTPUT_LINES);
  return (
    <section className="flow-step-section">
      <h4>{t("Output")}</h4>
      <div className="flow-output mono" role="region" aria-label={t("Output")} tabIndex={0}>
        {tail.hidden > 0 && <button type="button" className="flow-text-button" onClick={() => setAll(true)}>{t("Show {0} earlier lines", tail.hidden)}</button>}
        {tail.lines.map((line, index) => <div key={index} className="flow-output-line">{line || " "}</div>)}
      </div>
    </section>
  );
}

function Script({ title, script }: { title: string; script: string }) {
  return (
    <section className="flow-step-section">
      <h4>{title}</h4>
      <pre className="flow-script mono"><code>{script}</code></pre>
    </section>
  );
}

function Fact({ name, children }: { name: string; children: ReactNode }) {
  return <div className="flow-step-fact"><dt>{name}</dt><dd>{children}</dd></div>;
}
