import { ipc } from "@/shared/api";
import { env, joinPath } from "@/shared/config";
import { git } from "@/shared/platform";

/** Real native filesystem/process checks, including the Windows CI runner. */
export async function environmentPathsSelfTest(): Promise<[boolean, string]> {
  const root = joinPath(env.temp, `gitrochi-environment-${Date.now()}`);
  const repo = joinPath(root, "spaces and 한국어");
  try {
    await ipc.mkdirs(repo);
    await git(["init", "-q"], repo);
    const relative = "sources/" + "nested-segment/".repeat(6) + "sample-한글.txt";
    const file = joinPath(repo, relative);
    await ipc.mkdirs(file.slice(0, file.lastIndexOf("/")));
    await ipc.writeText(file, "Native Unicode path fixture\n");
    if (await ipc.readText(file) !== "Native Unicode path fixture\n") return [false, "Native Unicode/nested path read did not match"];
    const status = await git(["status", "--porcelain=v2", "-z", "--untracked-files=all"], repo);
    if (!status.stdout.includes(relative)) return [false, "Git did not preserve the Unicode nested path"];
    const missing = await ipc.hubRead("http://127.0.0.1:9/api/v1/repos/example.com/team/app/presence", "fixture-token").then(() => false, () => true);
    if (!missing) return [false, "An unavailable local hub did not reject the native read"];
    return [true, `Native filesystem + Git preserve spaces, Unicode and nested path (${file.length} characters); disconnected hub rejects without credentials in diagnostics. Physical installer/WSL verification remains environment-specific.`];
  } catch (error) {
    return [false, error instanceof Error ? error.message : String(error)];
  } finally { await ipc.remove(root).catch(() => {}); }
}
