import { afterEach, describe, expect, it, vi } from "vitest";
import { repositoryReadRuntime } from "@/entities/ai";
import { gitch } from "@/entities/gitch";
import { ipc } from "@/shared/api";
import { tools } from "@/shared/platform";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

afterEach(() => vi.restoreAllMocks());

describe("repository reader and workspace tool identity", () => {
  it("uses the workspace bundled CLI even when an installed CLI differs", async () => {
    vi.spyOn(tools, "path").mockReturnValue("/fixture/node");
    vi.spyOn(gitch, "bundled", "get").mockReturnValue("/bundle/gitch");
    const installed = vi.spyOn(gitch, "executable").mockResolvedValue("/installed/older-gitch");
    vi.spyOn(gitch, "bash").mockResolvedValue("/bin/bash");
    vi.spyOn(ipc, "exists").mockResolvedValue(true);
    vi.spyOn(ipc, "run").mockResolvedValue({ status: 0, stdout: "v22.0.0", stderr: "" });
    const runtime = await repositoryReadRuntime("C:/fixture/repo");
    expect(runtime.args[runtime.args.indexOf("--gitch") + 1]).toBe("/bundle/gitch");
    expect(runtime.args).not.toContain("/installed/older-gitch"); expect(installed).not.toHaveBeenCalled();
  });
  it("does not silently substitute an installed graph CLI when the bundle is absent", async () => {
    vi.spyOn(tools, "path").mockReturnValue("/fixture/node");
    vi.spyOn(gitch, "bundled", "get").mockReturnValue("/bundle/missing-gitch");
    const installed = vi.spyOn(gitch, "executable").mockResolvedValue("/installed/older-gitch");
    vi.spyOn(gitch, "bash").mockResolvedValue("/bin/bash");
    vi.spyOn(ipc, "exists").mockImplementation(async path => path !== "/bundle/missing-gitch");
    vi.spyOn(ipc, "run").mockResolvedValue({ status: 0, stdout: "v22.0.0", stderr: "" });
    const runtime = await repositoryReadRuntime("C:/fixture/repo");
    expect(runtime.args).not.toContain("--gitch"); expect(installed).not.toHaveBeenCalled();
  });
  it("mirrors bundled CLI selection and graph subprocess environment in the native reader", () => {
    const native = readFileSync(resolve("../macos/Sources/Services/RepositoryReader.swift"), "utf8");
    expect(native).toContain("if let gitch = Gitch.bundled"); expect(native).not.toContain("Gitch.executable");
    expect(native).toContain("environment: Gitch.environment"); expect(native).toContain("env: environment");
  });
});
