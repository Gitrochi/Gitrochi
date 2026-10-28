import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { readOnlyGraphArguments } from "../src/shared/platform/readonly-graph";

const bash = process.platform === "win32"
  ? [join(process.env.ProgramFiles ?? "C:/Program Files", "Git/bin/bash.exe"), resolve(execFileSync("git", ["--exec-path"], { encoding: "utf8" }).trim(), "../../../bin/bash.exe")].find(existsSync)
  : "/bin/bash";

describe("read-only graph subprocess boundary", () => {
  it("passes paths and graph arguments as data to the trusted Bash executable", () => {
    const args = ["graph", "files", "--out", "C:/fixture/한글 $(not-a-command).html"];
    const command = readOnlyGraphArguments("C:\\Program Files\\Git\\bin\\bash.exe", "C:\\fixture\\gitch", args);
    expect(command.slice(2)).toEqual(["C:/Program Files/Git/bin/bash.exe", "C:/fixture/gitch", ...args]);
    expect(command[1]).toContain('exec "$0" "$@"');
  });

  it("never runs configured FSMonitor hooks, including conflicting inherited runtime configuration", () => {
    if (!bash) throw new Error("Git Bash is required for the read-only graph subprocess test.");
    const fixture = mkdtempSync(join(tmpdir(), "gitrochi-readonly-graph-"));
    const cleanEnv = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("GIT_CONFIG_")));
    const git = (...args: string[]) => execFileSync("git", args, { cwd: fixture, env: cleanEnv, encoding: "utf8" });
    const marker = join(fixture, "hook-ran"), hook = join(fixture, "fsmonitor-hook");
    const portableHook = hook.replaceAll("\\", "/");
    const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
    const hookCommand = quote(portableHook);
    try {
      git("init", "-q");
      writeFileSync(join(fixture, "source.ts"), "export const fixture=1;\n");
      git("add", "source.ts");
      writeFileSync(hook, '#!/bin/sh\nprintf ran > "$(dirname "$0")/hook-ran"\nprintf "fixture-token\\0"\n');
      chmodSync(hook, 0o755);
      git("config", "core.fsmonitor", hookCommand);
      const originalConfig = readFileSync(join(fixture, ".git/config"), "utf8");
      git("ls-files");
      expect(existsSync(marker)).toBe(true);
      rmSync(marker);
      const cli = fileURLToPath(new URL("../../tools/gitch/gitch", import.meta.url));
      const probe = join(fixture, "read-config");
      writeFileSync(probe, 'git config --get "$1"\n');
      for (const inherited of [
        {},
        { GIT_CONFIG_PARAMETERS: quote("core.fsmonitor=" + hookCommand) + " " + quote("alias.fixture=preserved") },
        { GIT_CONFIG_COUNT: "2", GIT_CONFIG_KEY_0: "core.quotepath", GIT_CONFIG_VALUE_0: "false", GIT_CONFIG_KEY_1: "core.fsmonitor", GIT_CONFIG_VALUE_1: hookCommand },
        { GIT_CONFIG_COUNT: "1", GIT_CONFIG_KEY_0: "core.fsmonitor", GIT_CONFIG_VALUE_0: hookCommand, GIT_CONFIG_PARAMETERS: quote("core.fsmonitor=" + hookCommand) },
      ]) {
        const environment = { ...cleanEnv, ...inherited, XDG_CACHE_HOME: join(fixture, "cache").replaceAll("\\", "/"), GITSW_SWIFT_DESCRIBE: "0" };
        const raw = execFileSync(bash, readOnlyGraphArguments(bash, cli, ["graph", "files", "--json", "."]), { cwd: fixture, env: environment, encoding: "utf8", maxBuffer: 16_000_000 });
        expect(JSON.parse(raw).nodes.some((node: { id: string }) => node.id === "source.ts")).toBe(true);
        expect(existsSync(marker)).toBe(false);
        const value = execFileSync(bash, readOnlyGraphArguments(bash, probe, ["core.fsmonitor"]), { cwd: fixture, env: environment, encoding: "utf8" });
        expect(value.trim()).toBe("false");
        if (inherited.GIT_CONFIG_COUNT === "2") {
          const kept = execFileSync(bash, readOnlyGraphArguments(bash, probe, ["core.quotepath"]), { cwd: fixture, env: environment, encoding: "utf8" });
          expect(kept.trim()).toBe("false");
        }
      }
      expect(readFileSync(join(fixture, ".git/config"), "utf8")).toBe(originalConfig);
    } finally { rmSync(fixture, { recursive: true, force: true }); }
  }, 60_000);
});
