import { beforeEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ git: vi.fn(), bytes: vi.fn() }));
vi.mock("@/shared/platform", () => ({ git: mocks.git, gitBytes: mocks.bytes }));
import { browserImageLimit, loadRepositoryBlob, loadRepositoryTree, parseRepositoryTree, repositoryImageMime, safeRepositoryPath, type RepositoryTreeEntry } from "../src/entities/git/lib/repository-browser";
const a = "a".repeat(40), b = "b".repeat(40);
const entry: RepositoryTreeEntry = { path: "src/with space.ts", mode: "100644", oid: a, size: 5, kind: "file" };
const ok = (stdout: string) => ({ stdout, stderr: "", status: 0 });
beforeEach(() => { vi.resetAllMocks(); });
describe("repository browser", () => {
  it("parses exact literal file names, SHA256 objects, symlinks and submodules", () => {
    const rows = parseRepositoryTree(`100644 blob ${a}      5\tsrc/a [*].ts\0` + `120000 blob ${b} 8\tlink\0` + `160000 commit ${"c".repeat(64)} -\tmodule\0`);
    expect(rows.map((row) => [row.path, row.kind, row.size])).toEqual([["src/a [*].ts", "file", 5], ["link", "symlink", 8], ["module", "submodule", 0]]);
  });
  it("rejects traversal, absolute paths, control characters and malformed entries", () => {
    for (const path of ["../secret", "/etc/passwd", "a/../b", "a/./b", "a//b", "C:\\private", "a\nb", "a\0b"]) expect(safeRepositoryPath(path)).toBe(false);
    expect(parseRepositoryTree(`100644 blob oops 3\tfile\0`)).toEqual([]);
    expect(parseRepositoryTree(`100644 blob ${a} -1\tfile\0`)).toEqual([]);
  });
  it("resolves a branch once and lists the immutable commit", async () => {
    mocks.git.mockResolvedValueOnce(ok(a)).mockResolvedValueOnce(ok(`100644 blob ${b} 5\tfile\0`));
    const tree = await loadRepositoryTree("fixture", "feature/topic");
    expect(tree.revision).toBe(a); expect(tree.entries[0].oid).toBe(b);
    expect(mocks.git.mock.calls[1][0]).toEqual(["ls-tree", "-r", "-z", "-l", a, "--"]);
  });
  it("blocks revision option injection before any Git process", async () => {
    await expect(loadRepositoryTree("fixture", "--output=secret")).rejects.toThrow(); expect(mocks.git).not.toHaveBeenCalled();
  });
  it("reads a blob by object ID instead of following paths", async () => {
    mocks.git.mockResolvedValue(ok("5")); mocks.bytes.mockResolvedValue(btoa("hello"));
    expect(await loadRepositoryBlob("fixture", entry)).toEqual({ text: "hello", notice: undefined });
    expect(mocks.bytes).toHaveBeenCalledWith(["cat-file", "blob", a], "fixture");
  });
  it("shows a symbolic link target as plain data", async () => {
    mocks.git.mockResolvedValue(ok("11")); mocks.bytes.mockResolvedValue(btoa("/etc/passwd"));
    const result = await loadRepositoryBlob("fixture", { ...entry, mode: "120000", kind: "symlink", size: 11 });
    expect(result.text).toBe("/etc/passwd"); expect(result.notice).toContain("never followed"); expect(result.image).toBeUndefined();
  });
  it("does not read a submodule or a blob beyond the size limit", async () => {
    expect((await loadRepositoryBlob("fixture", { ...entry, kind: "submodule", mode: "160000" })).text).toBe(a);
    expect((await loadRepositoryBlob("fixture", { ...entry, size: browserImageLimit + 1 })).notice).toContain("8 MB");
    expect(mocks.git).not.toHaveBeenCalled(); expect(mocks.bytes).not.toHaveBeenCalled();
  });
  it("checks actual object size before loading bytes", async () => {
    mocks.git.mockResolvedValue(ok("70000000")); await expect(loadRepositoryBlob("fixture", entry)).rejects.toThrow(); expect(mocks.bytes).not.toHaveBeenCalled();
  });
  it("detects binary bytes and prevents HTML or SVG image interpretation", async () => {
    mocks.git.mockResolvedValue(ok("5")); mocks.bytes.mockResolvedValue(btoa("a\0bcd"));
    expect((await loadRepositoryBlob("fixture", entry)).notice).toContain("Binary");
    expect(repositoryImageMime(new TextEncoder().encode("<svg onload=alert(1)>"))).toBeNull();
    expect(repositoryImageMime(Uint8Array.from([137,80,78,71,13,10,26,10]))).toBe("image/png");
  });
  it("renders recognized image data without fetching a remote URL", async () => {
    const binary = "GIF89aabc"; mocks.git.mockResolvedValue(ok(String(binary.length))); mocks.bytes.mockResolvedValue(btoa(binary));
    expect((await loadRepositoryBlob("fixture", { ...entry, size: binary.length })).image).toBe(`data:image/gif;base64,${btoa(binary)}`);
  });
  it("rejects incomplete native byte output", async () => {
    mocks.git.mockResolvedValue(ok("5")); mocks.bytes.mockResolvedValue(btoa("abc"));
    await expect(loadRepositoryBlob("fixture", entry)).rejects.toThrow();
  });
});
