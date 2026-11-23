import { describe, expect, it } from "vitest";
import { fileIcon } from "../src/shared/lib/file-icon";

describe("file type icons", () => {
  it("colours source code by language and other files by type", () => {
    expect(fileIcon("macos/Sources/App.swift")).toEqual({ kind: "code", color: "#f05138" });
    expect(fileIcon("src\\app\\main.TSX")).toEqual({ kind: "code", color: "#3178c6" });
    expect(fileIcon("data/config.json").kind).toBe("json");
    expect(fileIcon("docs/README.md").kind).toBe("markdown");
    expect(fileIcon("assets/logo.png").kind).toBe("image");
    expect(fileIcon("release.tar.gz").kind).toBe("archive");
  });
  it("knows some files by their whole name", () => {
    expect(fileIcon("Dockerfile").kind).toBe("docker");
    expect(fileIcon("build/Dockerfile.prod").kind).toBe("docker");
    expect(fileIcon(".gitignore").kind).toBe("git");
    expect(fileIcon("windows/package-lock.json").kind).toBe("lock");
    expect(fileIcon(".env.local").kind).toBe("config");
  });
  it("falls back to a plain grey file", () => {
    expect(fileIcon("NOTES")).toEqual({ kind: "file", color: null });
    expect(fileIcon("archive.unknownext")).toEqual({ kind: "file", color: null });
  });
});
