import type { WorkContext } from "./work-context";

export interface WorkPrompt { id: string; title: string; template: string }
/** Task starters remain editable and never send a question on selection. */
export const workPrompts: readonly WorkPrompt[] = [
  { id: "structure", title: "Understand this area", template: "Explain the responsibilities and dependencies of the selected area. Cite files and distinguish verified relationships from inferred ones." },
  { id: "impact", title: "Assess change impact", template: "Trace the selected changes to their direct and indirect dependents. Explain the evidence, missing coverage and likely review priorities." },
  { id: "review", title: "Review selected changes", template: "Review the selected changes for concrete correctness risks. Give a reproducible trigger and file evidence for each finding; distinguish facts from hypotheses." },
  { id: "tests", title: "Plan relevant tests", template: "Identify relevant existing tests for this selection and explain each match. Separate suggested tests from executed results and do not invent commands." },
  { id: "performance", title: "Investigate performance", template: "Find plausible performance bottlenecks in this selection and propose a bounded measurement. Cite the code and separate measured facts from untested hypotheses." },
];
const selectionText = (context: Pick<WorkContext, "selectedPaths" | "scope" | "screenID">, translate: (key: string) => string) => `\n\n${translate("Screen")}: ${context.screenID}\n${translate("Scope")}: ${context.scope}\n${translate("Selected paths")}: ${context.selectedPaths.length ? context.selectedPaths.join(", ") : translate("No files selected")}`;
export function renderWorkPrompt(id: string, context: Pick<WorkContext, "selectedPaths" | "scope" | "screenID">, translate: (key: string) => string = (key) => key, template?: string): string {
  const prompt = workPrompts.find((item) => item.id === id);
  return prompt ? (template ?? translate(prompt.template)) + selectionText(context, translate) : "";
}
/** Save the editable instruction without freezing the generated selection footer. */
export function workPromptTemplate(question: string, context: Pick<WorkContext, "selectedPaths" | "scope" | "screenID">, translate: (key: string) => string = (key) => key): string {
  const suffix = selectionText(context, translate);
  return (question.endsWith(suffix) ? question.slice(0, -suffix.length) : question).trim();
}
