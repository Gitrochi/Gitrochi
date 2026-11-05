import type { FlowDocument } from "./design";

export interface FlowCreationDraft {
  name: string;
  description: string;
  parallel: boolean;
  steps: { title: string; command: string }[];
}

export type FlowCreationProblem = "name-required" | "name-invalid" | "name-exists" | "steps-required" | "command-required";

/** Keep guided creation portable and reject collisions before any file is written. macOS: FlowCreation.swift. */
export function flowCreationProblem(draft: FlowCreationDraft, existingNames: string[]): FlowCreationProblem | null {
  const name = draft.name.trim();
  if (!name) return "name-required";
  if (!/^[a-z][a-z0-9_-]{0,63}$/.test(name)) return "name-invalid";
  if (existingNames.some((existing) => existing.toLowerCase() === name.toLowerCase())) return "name-exists";
  if (!draft.steps.length) return "steps-required";
  if (draft.steps.some((step) => !step.command.trim())) return "command-required";
  return null;
}

/** Display order defines sequential dependencies; command text stays exactly as authored. macOS: FlowCreation.swift. */
export function flowCreationDocument(draft: FlowCreationDraft): FlowDocument {
  const description = draft.description.trim();
  const nodes = Object.fromEntries(draft.steps.map((step, index) => {
    const title = step.title.trim();
    const node: FlowDocument = {
      ...(title ? { description: title } : {}),
      run: step.command,
      ...(!draft.parallel && index > 0 ? { needs: [`step-${index}`] } : {}),
    };
    return [`step-${index + 1}`, node];
  }));
  return {
    version: 1,
    flows: {
      [draft.name.trim()]: {
        ...(description ? { description } : {}),
        trigger: ["manual"],
        nodes,
      },
    },
  };
}

/** A validated name gets its own file so existing flow sources remain intact. */
export function flowCreationFile(name: string): string {
  return `.gitch/flows/${name.trim()}.yml`;
}
