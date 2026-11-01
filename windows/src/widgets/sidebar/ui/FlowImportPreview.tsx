import { FileCode2, TriangleAlert } from "lucide-react";
import { useState } from "react";
import { type FlowDesignInspection, flowObject, importedDesignModules } from "@/entities/flow";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { FlowGraph } from "./FlowGraph";

/** External workflows are inspected first, and a remote wrapper is proposed only when supported. */
export function FlowImportPreview({ inspection, fileName, target, onTarget, onUse, onCancel }: { inspection: FlowDesignInspection; fileName: string; target: string; onTarget: (value: string) => void; onUse: () => void; onCancel: () => void }) {
  const modules = importedDesignModules(inspection);
  const [choice, setChoice] = useState<string | null>(null);
  const selected = modules.find((module) => module.id === choice) ?? modules[0];
  const supported = inspection.format === "flow" && inspection.editable && inspection.document !== null;
  const compose = inspection.format === "compose" && inspection.document !== null && modules.length > 0 && !inspection.diagnostics.some((diagnostic) => diagnostic.severity === "error");
  const usable = supported || inspection.proposal !== null || compose;
  const diagnostics = inspection.diagnostics.filter((diagnostic, index, all) => all.findIndex((entry) => entry.code === diagnostic.code && entry.message === diagnostic.message) === index);
  return <div className="flow-import-preview" data-flow-import-preview>
    <div className="flow-import-heading"><FileCode2 size={22} /><div><strong>{fileName}</strong><span>{inspection.format === "github" ? "GitHub Actions" : inspection.format === "gitlab" ? "GitLab CI" : inspection.format === "compose" ? "Docker Compose" : inspection.format === "jenkins" ? "Jenkins" : inspection.format === "flow" ? "Gitrochi Flow" : t("Unrecognized format")}</span></div></div>
    <p>{t("Preview only. The source file stays unchanged and no commands run.")}</p>
    {modules.length > 0 && <div className="flow-import-body"><div className="flow-import-graph"><FlowGraph fitOnMount nodes={modules} selected={selected?.id ?? null} onSelect={setChoice} /></div>{selected && <ImportedModuleDetail inspection={inspection} id={selected.id} run={selected.run} />}</div>}
    {inspection.proposal && <p className="flow-import-explanation">{t("This file is a remote CI definition. The proposed module starts and follows the original workflow on its provider; it does not run its scripts locally.")}</p>}
    {inspection.format === "compose" && <p className="flow-import-explanation">{t("Compose services are shown with their dependencies. Keep this file as the source and configure Docker modules for the work you want to run.")}</p>}
    {diagnostics.map((diagnostic, index) => <div key={index} className={`flow-design-diagnostic ${diagnostic.severity}`}><TriangleAlert size={13} /><span>{t(diagnostic.message)}{diagnostic.line ? ` · ${t("Line {0}", diagnostic.line)}` : ""}</span></div>)}
    {usable && <label className="flow-form-field"><span>{t("Import into this repository")}</span><input aria-label={t("Imported flow file")} className="mono" value={target} onChange={(event) => onTarget(event.target.value)} /><small>{t("Choose a new .gitch/flows/*.yml file. Existing files will not be overwritten.")}</small></label>}
    <details><summary>{t("Source definition")}</summary><pre className="flow-script mono">{inspection.yaml}</pre></details>
    <div className="row" style={{ gap: 8 }}><span className="spacer" /><Button onClick={onCancel}>{t("Cancel")}</Button>{usable && <Button kind="primary" onClick={onUse}>{compose ? t("Configure Compose deployment") : inspection.proposal ? t("Review proposed module") : t("Use imported modules")}</Button>}</div>
  </div>;
}

function ImportedModuleDetail({ inspection, id, run }: { inspection: FlowDesignInspection; id: string; run?: string }) {
  const doc = inspection.document ?? {};
  const source = flowObject(inspection.format === "github" ? flowObject(doc.jobs)[id] : inspection.format === "compose" ? flowObject(doc.services)[id] : doc[id]);
  const githubSteps = Array.isArray(source.steps) ? source.steps.map(flowObject) : [];
  const strings = (value: unknown): string[] => typeof value === "string" ? [value] : Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
  const sections = inspection.format === "gitlab" ? [
    { title: t("Before script"), lines: strings(source.before_script) },
    { title: t("Command"), lines: strings(source.script) },
    { title: t("After script"), lines: strings(source.after_script) },
  ] : run ? [{ title: t("Command"), lines: [run] }] : [];
  const runner = strings(source["runs-on"] ?? source.tags ?? source.image).join(", ");
  const environment = Object.keys(flowObject(source.env ?? source.environment ?? source.variables));
  return <aside className="flow-import-module"><h3>{id}</h3><dl>{runner && <><dt>{inspection.format === "compose" ? t("Container image") : t("Runner")}</dt><dd>{runner}</dd></>}{typeof source.if === "string" && <><dt>{t("Condition")}</dt><dd className="mono">{source.if}</dd></>}{environment.length > 0 && <><dt>{t("Environment keys")}</dt><dd>{environment.join(", ")}</dd></>}</dl>
    {githubSteps.map((step, index) => <section className="flow-import-step" key={index}><strong>{typeof step.name === "string" ? step.name : t("Step {0}", index + 1)}</strong>{typeof step.uses === "string" && <p><span>{t("Action")}</span><code>{step.uses}</code></p>}{typeof step.run === "string" && <pre className="flow-script mono">{step.run}</pre>}{typeof step.if === "string" && <p>{t("Condition")}: <code>{step.if}</code></p>}</section>)}
    {sections.filter((section) => section.lines.length).map((section) => <section className="flow-import-step" key={section.title}><strong>{section.title}</strong><pre className="flow-script mono">{section.lines.join("\n")}</pre></section>)}
    {inspection.format === "compose" && ["ports", "volumes", "command"].map((key) => strings(source[key]).length > 0 && <section className="flow-import-step" key={key}><strong>{key}</strong><pre className="flow-script mono">{strings(source[key]).join("\n")}</pre></section>)}
    {!githubSteps.length && !sections.some((section) => section.lines.length) && inspection.format !== "compose" && <p className="muted">{t("Additional module settings remain in the complete source definition.")}</p>}
  </aside>;
}
