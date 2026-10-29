import { beforeEach, describe, expect, it, vi } from "vitest";

const native = vi.hoisted(() => ({ list: vi.fn(), open: vi.fn() }));
vi.mock("@/shared/api", () => ({ ipc: { externalEditors: native.list, openExternalEditor: native.open } }));
import { externalEditors } from "../src/shared/platform/editors";

beforeEach(() => vi.resetAllMocks());

describe("native external editor bridge", () => {
  it("returns native availability without exposing executable paths", async () => {
    const editors = [{ id: "vscode", name: "Visual Studio Code", available: true, supportsFolders: true }];
    native.list.mockResolvedValue(editors);
    expect(await externalEditors.list()).toEqual(editors);
  });

  it("keeps the repository and relative working-copy file as separate native arguments", async () => {
    await externalEditors.open("C:/fixture", "vscode", "src/a 'quote' & file.ts");
    expect(native.open).toHaveBeenCalledWith("C:/fixture", "vscode", "src/a 'quote' & file.ts");
    await externalEditors.open("C:/fixture", "intellij");
    expect(native.open).toHaveBeenLastCalledWith("C:/fixture", "intellij", undefined);
  });

  it("preserves native validation errors for the UI", async () => {
    native.open.mockRejectedValue(new Error("The local file is missing or is not a regular file."));
    await expect(externalEditors.open("C:/fixture", "notepad", "missing.ts")).rejects.toThrow("missing");
  });
});
