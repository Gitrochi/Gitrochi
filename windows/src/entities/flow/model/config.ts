import { ipc } from "@/shared/api";
import { joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { flowEngine } from "./engine";

export const scriptFlowExample = "version: 1\nflows:\n  verify:\n    description: Build and check this repository\n    trigger: [manual]\n    nodes:\n      prepare:\n        run: |\n          echo Preparing workspace\n      check:\n        needs: [prepare]\n        run: |\n          echo Replace this command with your test script\n      finish:\n        needs: [check]\n        run: echo Checks complete\n";

/** All configuration sources the engine reads; local overlays remain editable separately. */
export async function flowConfigFiles(repo: string): Promise<string[]> {
  const main = await ipc.exists(joinPath(repo, ".gitch/flow.yml")) ? ".gitch/flow.yml" : await ipc.exists(joinPath(repo, ".gitch/flow.yaml")) ? ".gitch/flow.yaml" : null;
  const parts = await ipc.list(joinPath(repo, ".gitch/flows")).catch(() => []);
  const files = [...(main ? [main] : []), ...parts.filter((file) => /\.ya?ml$/.test(file) && !file.startsWith(".")).sort().map((file) => `.gitch/flows/${file}`)];
  for (const overlay of [".gitch/flow.local.yml", ".gitch/flow.local.yaml"]) if (await ipc.exists(joinPath(repo, overlay))) files.push(overlay);
  return files;
}

/** Save only the version the editor opened, and restore it when engine validation fails. */
export async function saveFlowConfig(repo: string, file: string, original: string | null, draft: string): Promise<void> {
  if (!/^\.gitch\/(?:flow(?:\.local)?\.ya?ml|flows\/[^/\\]+\.ya?ml)$/.test(file)) throw new Error(t("Choose a flow configuration file."));
  if (!draft.trim()) throw new Error(t("The flow file cannot be empty."));
  const path = joinPath(repo, file);
  if (await ipc.readText(path) !== original) throw new Error(t("The flow file changed outside this editor. Reopen it before saving."));
  const saved = draft.endsWith("\n") ? draft : draft + "\n";
  await ipc.writeText(path, saved);
  try {
    await flowEngine.validate(repo);
  } catch (error) {
    // Do not overwrite an external edit made while validation was in progress.
    if (await ipc.readText(path) !== saved) throw new Error(t("The flow file changed during validation. Reopen it to review the current contents."));
    if (original === null) await ipc.remove(path);
    else await ipc.writeText(path, original);
    throw error;
  }
}
