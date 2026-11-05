import { ArrowDown, ArrowUp, Plus, Trash2, Workflow } from "lucide-react";
import { useRef, useState } from "react";
import { checkedDesignYaml, flowCreationDocument, flowCreationFile, flowCreationProblem, flowEngine, saveFlowConfig, type FlowCreationDraft, type FlowCreationProblem, type FlowStore } from "@/entities/flow";
import { ipc } from "@/shared/api";
import { joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Button, IconButton, Modal, Spinner } from "@/shared/ui";
import "./flow-create.css";

const problemText = (problem: FlowCreationProblem) => t({
  "name-required": "Enter a flow name.",
  "name-invalid": "Use 1–64 lowercase letters, numbers, hyphens or underscores, starting with a letter.",
  "name-exists": "A flow with this name already exists.",
  "steps-required": "Add at least one step.",
  "command-required": "Enter a command for every step.",
}[problem]);

interface DraftStep { key: number; title: string; command: string }

/** A command-first form creates a separate validated flow without running its commands. */
export function FlowCreateDialog({ flows, onClose, onCreated }: { flows: FlowStore; onClose: () => void; onCreated: (name: string) => void }) {
  const [name, setName] = useState(""), [description, setDescription] = useState(""), [parallel, setParallel] = useState(false);
  const [steps, setSteps] = useState<DraftStep[]>([{ key: 0, title: "", command: "" }]);
  const [saving, setSaving] = useState(false), [error, setError] = useState<string | null>(null);
  const [discard, setDiscard] = useState(false);
  const [savedName, setSavedName] = useState<string | null>(null);
  const nextKey = useRef(1), busy = useRef(false), nameInput = useRef<HTMLInputElement>(null);
  const commands = useRef(new Map<number, HTMLTextAreaElement>());
  const draft: FlowCreationDraft = { name, description, parallel, steps };
  const dirty = !!name || !!description || parallel || steps.length > 1 || steps.some((step) => !!step.title || !!step.command);
  const close = () => { if (busy.current) return; if (savedName) onCreated(savedName); else if (dirty) setDiscard(true); else onClose(); };
  const reportProblem = (problem: FlowCreationProblem) => {
    setError(problemText(problem));
    requestAnimationFrame(() => {
      if (problem.startsWith("name-")) nameInput.current?.focus();
      else if (problem === "command-required") {
        const empty = steps.find((step) => !step.command.trim());
        if (empty) commands.current.get(empty.key)?.focus();
      }
    });
  };
  const create = async () => {
    if (busy.current) return;
    const problem = flowCreationProblem(draft, flows.list?.flows.map((flow) => flow.name) ?? []);
    if (!savedName && problem) { reportProblem(problem); return; }
    busy.current = true; setSaving(true); setError(null);
    try {
      if (savedName) { await flows.refresh(); onCreated(savedName); return; }
      const existing = await flowEngine.hasFlowFile(flows.repo) ? (await flowEngine.list(flows.repo)).flows.map((flow) => flow.name) : [];
      const currentProblem = flowCreationProblem(draft, existing);
      if (currentProblem) { reportProblem(currentProblem); return; }
      const file = flowCreationFile(name);
      if (await ipc.exists(joinPath(flows.repo, file))) throw new Error(t("That flow file already exists. Choose a new file name."));
      const rendered = await flowEngine.renderDesign(flowCreationDocument(draft), "", flows.repo);
      const yaml = checkedDesignYaml(rendered);
      await saveFlowConfig(flows.repo, file, null, yaml);
      setSavedName(name.trim());
      await flows.refresh();
      onCreated(name.trim());
    } catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)); }
    finally { busy.current = false; setSaving(false); }
  };
  const update = (key: number, patch: Partial<Pick<DraftStep, "title" | "command">>) => { setError(null); setSteps((current) => current.map((step) => step.key === key ? { ...step, ...patch } : step)); };
  const move = (index: number, offset: number) => setSteps((current) => {
    if (index + offset < 0 || index + offset >= current.length) return current;
    const next = current.slice();
    [next[index], next[index + offset]] = [next[index + offset], next[index]];
    return next;
  });
  const add = () => {
    setError(null);
    const key = nextKey.current++;
    setSteps((current) => [...current, { key, title: "", command: "" }]);
    requestAnimationFrame(() => commands.current.get(key)?.focus());
  };
  return <><Modal title={t("Create flow")} width={680} onClose={close} footer={<><Button disabled={saving} onClick={close}>{savedName ? t("Close") : t("Cancel")}</Button><Button kind="primary" disabled={saving} onClick={() => void create()}>{saving ? <Spinner size={13} /> : <Plus size={14} />}{savedName ? t("Try again") : t("Create flow")}</Button></>}>
    <div className="flow-create" data-flow-create>
      <div className="flow-create-intro"><span className="flow-create-emblem"><Workflow size={22} /></span><div><strong>{t("Build a flow from your commands.")}</strong><p>{t("Commands run from the repository folder.")}</p></div></div>
      <fieldset className="flow-create-fields" disabled={saving || !!savedName}>
        <label>{t("Flow name")}<input ref={nameInput} autoFocus value={name} autoCapitalize="off" autoCorrect="off" spellCheck={false} onChange={(event) => { setName(event.target.value); setError(null); }} aria-describedby="flow-create-name-help" /></label>
        <p className="flow-create-help" id="flow-create-name-help">{t("Use 1–64 lowercase letters, numbers, hyphens or underscores, starting with a letter.")}</p>
        <label>{t("Description")}<input value={description} placeholder={t("Optional")} onChange={(event) => setDescription(event.target.value)} /></label>
        <div className="flow-create-order"><label>{t("Execution")}<select value={parallel ? "parallel" : "sequential"} onChange={(event) => setParallel(event.target.value === "parallel")}><option value="sequential">{t("In order")}</option><option value="parallel">{t("In parallel")}</option></select></label><p className="flow-create-help">{parallel ? t("Steps run independently at the same time.") : t("Each step starts after the previous step succeeds.")}</p></div>
        <div className="flow-create-step-list">{steps.map((step, index) => <section className="flow-create-step" data-flow-create-step key={step.key} aria-label={`${t("Step")} ${index + 1}`}>
          <header><span className="flow-create-number">{index + 1}</span><strong>{t("Step")} {index + 1}</strong><span className="spacer" /><IconButton small icon={<ArrowUp size={14} />} tip={t("Move up")} aria-label={t("Move up")} disabled={index === 0} onClick={() => move(index, -1)} /><IconButton small icon={<ArrowDown size={14} />} tip={t("Move down")} aria-label={t("Move down")} disabled={index === steps.length - 1} onClick={() => move(index, 1)} /><IconButton small icon={<Trash2 size={14} />} tip={t("Remove step")} aria-label={t("Remove step")} disabled={steps.length === 1} onClick={() => setSteps((current) => current.filter((entry) => entry.key !== step.key))} /></header>
          <label>{t("Step title (optional)")}<input value={step.title} onChange={(event) => update(step.key, { title: event.target.value })} /></label>
          <label>{t("Command")}<textarea ref={(element) => { if (element) commands.current.set(step.key, element); else commands.current.delete(step.key); }} className="mono" value={step.command} rows={3} autoCapitalize="off" autoCorrect="off" spellCheck={false} onChange={(event) => update(step.key, { command: event.target.value })} /></label>
        </section>)}</div>
        <Button className="flow-create-add" onClick={add}><Plus size={14} />{t("Add step")}</Button>
      </fieldset>
      <p className="flow-create-help">{t("Creating a flow saves it without running commands.")}</p>
      {savedName && <p className="flow-create-help" role="status">{t("Flow created. Review its commands, then run it.")}</p>}
      {error && <p className="flow-create-error error-text" role="alert">{error}</p>}
    </div>
  </Modal>{discard && <Modal title={t("Discard unsaved changes?")} width={420} onClose={() => setDiscard(false)} footer={<><Button onClick={() => setDiscard(false)}>{t("Keep editing")}</Button><Button kind="danger" onClick={onClose}>{t("Discard changes")}</Button></>} />}</>;
}
