import { ipc } from "@/shared/api";
import { joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { flowEngine } from "./engine";

export const scriptFlowExample = "version: 1\nflows:\n  verify:\n    description: Build and check this repository\n    trigger: [manual]\n    nodes:\n      prepare:\n        run: |\n          echo Preparing workspace\n      check:\n        needs: [prepare]\n        run: |\n          echo Replace this command with your test script\n      finish:\n        needs: [check]\n        run: echo Checks complete\n";

export interface FlowImportSource { yaml: string; fileName: string }

/** Read a bounded local source for preview; importing never writes to that source. */
export async function readFlowImport(path: string): Promise<FlowImportSource> {
  const head = await ipc.readHead(path, 2 * 1024 * 1024);
  if (head.binary || head.truncated || head.utf8 === false || head.text.includes("\0")) throw new Error(t("Choose a UTF-8 workflow file smaller than 2 MB."));
  return { yaml: head.text, fileName: path.replace(/^.*[/\\]/, "") };
}

export async function readWebFlowImport(file: Pick<File, "size" | "name" | "arrayBuffer">): Promise<FlowImportSource> {
  if (file.size > 2 * 1024 * 1024) throw new Error(t("Choose a UTF-8 workflow file smaller than 2 MB."));
  try {
    const yaml = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(await file.arrayBuffer());
    if (yaml.includes("\0")) throw new Error("binary");
    return { yaml, fileName: file.name };
  } catch { throw new Error(t("Choose a UTF-8 workflow file smaller than 2 MB.")); }
}

/** All configuration sources the engine reads; local overlays remain editable separately. */
export async function flowConfigFiles(repo: string): Promise<string[]> {
  const main = await ipc.exists(joinPath(repo, ".gitch/flow.yml")) ? ".gitch/flow.yml" : await ipc.exists(joinPath(repo, ".gitch/flow.yaml")) ? ".gitch/flow.yaml" : null;
  const parts = await ipc.list(joinPath(repo, ".gitch/flows")).catch(() => []);
  const files = [...(main ? [main] : []), ...parts.filter((file) => /\.ya?ml$/.test(file) && !file.startsWith(".")).sort().map((file) => `.gitch/flows/${file}`)];
  for (const overlay of [".gitch/flow.local.yml", ".gitch/flow.local.yaml"]) if (await ipc.exists(joinPath(repo, overlay))) files.push(overlay);
  return files;
}

export interface FlowAttachment { file: string; yaml: string }

/** Save the reviewed document and new imports together; reject external edits and restore failed validation. */
export async function saveFlowConfig(repo: string, file: string, original: string | null, draft: string, attachments: FlowAttachment[] = []): Promise<void> {
  if (!/^\.gitch\/(?:flow(?:\.local)?\.ya?ml|flows\/[^/\\]+\.ya?ml)$/.test(file)) throw new Error(t("Choose a flow configuration file."));
  if (!draft.trim()) throw new Error(t("The flow file cannot be empty."));
  if (attachments.some((attachment) => !/^\.gitch\/imports\/[A-Za-z0-9][A-Za-z0-9_.-]*\.ya?ml$/.test(attachment.file)) || new Set(attachments.map((attachment) => attachment.file)).size !== attachments.length) throw new Error(t("Choose new files inside .gitch/imports for imported sources."));
  const path = joinPath(repo, file);
  if (await ipc.readText(path) !== original) throw new Error(t("The flow file changed outside this editor. Reopen it before saving."));
  const created: FlowAttachment[] = [];
  let wroteFlow = false;
  try {
    for (const attachment of attachments) {
      await ipc.createText(joinPath(repo, attachment.file), attachment.yaml);
      created.push(attachment);
    }
    if (original === null) await ipc.createText(path, draft);
    else await ipc.writeText(path, draft);
    wroteFlow = true;
    await flowEngine.validate(repo);
  } catch (error) {
    // A separate editor may have changed this file while the engine was checking it.
    if (wroteFlow && await ipc.readText(path) !== draft) throw new Error(t("The flow file changed during validation. Reopen it to review the current contents."));
    if (wroteFlow) {
      if (original === null) await ipc.remove(path);
      else await ipc.writeText(path, original);
    }
    for (const attachment of created.reverse()) {
      const target = joinPath(repo, attachment.file);
      if (await ipc.readText(target) === attachment.yaml) await ipc.remove(target);
    }
    throw error;
  }
}
