import { describe, expect, it } from "vitest";
import type { RepositoryTreeEntry } from "../src/entities/git";
import { repositoryLanguage, summarizeRepositoryLanguages } from "../src/widgets/local-workbench/lib/repository-languages";

const entry = (path: string, size = 10, kind: RepositoryTreeEntry["kind"] = "file"): RepositoryTreeEntry => ({ path, size, kind, mode: kind === "file" ? "100644" : kind === "symlink" ? "120000" : "160000", oid: "a".repeat(40) });
describe("repository language composition", () => {
  it("normalizes source variants and recognizes documents, configuration and build files", () => {
    expect(["a.ts", "a.tsx", "a.mts", "a.cts"].map(repositoryLanguage)).toEqual(Array(4).fill("TypeScript"));
    expect(["a.js", "a.jsx", "a.mjs", "a.cjs"].map(repositoryLanguage)).toEqual(Array(4).fill("JavaScript"));
    expect(["README.md", "docs/index.HTM", "a.jsonc", "a.yaml", ".gitignore", "Dockerfile", "Containerfile", "Makefile", "a.rst", "a.png"].map(repositoryLanguage)).toEqual(["Markdown", "HTML", "JSON", "YAML", "Configuration", "Dockerfile", "Dockerfile", "Makefile", "reStructuredText", "Other files"]);
    expect(["swift", ".json", ".config.json", "path/.editorconfig"].map(repositoryLanguage)).toEqual(["Other files", "Other files", "JSON", "Configuration"]);
  });
  it("uses file count rather than byte volume and excludes symbolic links and submodules", () => {
    const summary = summarizeRepositoryLanguages([entry("src/a.ts", 5), entry("src/b.tsx", 15), entry("docs/README.md", 1_000_000), entry("logo.png", 100), entry("linked.swift", 100, "symlink"), entry("module", 0, "submodule")]);
    expect(summary.files).toBe(4); expect(summary.bytes).toBe(1_000_120);
    expect(summary.languages.map(({ name, files, share }) => ({ name, files, share }))).toEqual([{ name: "TypeScript", files: 2, share: 0.5 }, { name: "Markdown", files: 1, share: 0.25 }, { name: "Other files", files: 1, share: 0.25 }]);
  });
  it("handles empty trees and zero-byte files without invalid percentages", () => {
    expect(summarizeRepositoryLanguages([])).toEqual({ files: 0, bytes: 0, languages: [] });
    expect(summarizeRepositoryLanguages([entry("empty.ts", 0)]).languages[0]).toMatchObject({ files: 1, bytes: 0, share: 1 });
  });
});
