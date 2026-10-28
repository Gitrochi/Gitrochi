import { describe, expect, it } from "vitest";
import { closeCodeFile, codeHistoryLimit, codeLineRange, codeOutline, codeRecentLimit, codeSymbolLimit, codeTabLimit, emptyCodeNavigation, quickOpenLimit, rankCodeFiles, stepCodeHistory, visitCodeLocation } from "../src/widgets/local-workbench/lib/code-navigation";

describe("code reading navigation", () => {
  it("bounds unique tabs and recents while keeping the last selected file open", () => {
    let state = emptyCodeNavigation();
    for (let i = 0; i < 80; i++) state = visitCodeLocation(state, { path: `src/file-${i}.ts`, mode: "Source" });
    expect(state.tabs).toHaveLength(codeTabLimit);
    expect(state.recent).toHaveLength(codeRecentLimit);
    expect(state.history).toHaveLength(codeHistoryLimit);
    expect(state.tabs.at(-1)?.path).toBe("src/file-79.ts");
    state = visitCodeLocation(state, { path: "src/file-79.ts", mode: "Blame" });
    expect(state.tabs).toHaveLength(codeTabLimit);
    expect(state.tabs.at(-1)?.mode).toBe("Blame");
    expect(new Set(state.recent).size).toBe(codeRecentLimit);
  });
  it("preserves view mode in history, skips repeated locations and truncates forward branches", () => {
    let state = visitCodeLocation(emptyCodeNavigation(), { path: "src/a.ts", mode: "Source" });
    state = visitCodeLocation(state, { path: "src/a.ts", mode: "Source" });
    state = visitCodeLocation(state, { path: "src/a.ts", mode: "Blame" });
    state = visitCodeLocation(state, { path: "src/b.ts", mode: "Source" });
    expect(state.history).toHaveLength(3);
    const back = stepCodeHistory(state, -1);
    expect(back.location).toEqual({ path: "src/a.ts", mode: "Blame" });
    state = visitCodeLocation(back.state, back.location!, false);
    expect(state.history).toHaveLength(3);
    state = visitCodeLocation(state, { path: "src/c.ts", mode: "Source" });
    expect(state.history.map((item) => item.path)).toEqual(["src/a.ts", "src/a.ts", "src/c.ts"]);
    expect(stepCodeHistory(state, 1).location).toBeNull();
    expect(stepCodeHistory(emptyCodeNavigation(), -1).location).toBeNull();
  });
  it("closes active tabs to an adjacent file while keeping inactive closure and history independent", () => {
    let state = emptyCodeNavigation();
    for (const path of ["a.ts", "b.ts", "c.ts"]) state = visitCodeLocation(state, { path, mode: "Source" });
    const inactive = closeCodeFile(state, "a.ts", "b.ts");
    expect(inactive.next).toBeNull();
    expect(inactive.state.tabs.map((tab) => tab.path)).toEqual(["b.ts", "c.ts"]);
    const middle = closeCodeFile(state, "b.ts", "b.ts");
    expect(middle.next?.path).toBe("c.ts");
    const last = closeCodeFile(state, "c.ts", "c.ts");
    expect(last.next?.path).toBe("b.ts");
    expect(last.state.history).toEqual(state.history);
    expect(closeCodeFile(visitCodeLocation(emptyCodeNavigation(), { path: "a", mode: "Source" }), "a", "a").next).toBeNull();
    expect(emptyCodeNavigation()).toEqual({ tabs: [], recent: [], history: [], cursor: -1 });
  });
  it("ranks exact names before prefixes and path matches, with recent files on empty queries", () => {
    const entries = ["src/Card.tsx", "Card.tsx", "src/Card.test.tsx", "src/cards/Button.tsx", "src/UserCard.tsx"].map((path) => ({ path }));
    expect(rankCodeFiles(entries, "card.tsx", []).map((file) => file.path)).toEqual(["Card.tsx", "src/Card.tsx", "src/UserCard.tsx"]);
    expect(rankCodeFiles(entries, "card", [])[0].path).toBe("Card.tsx");
    expect(rankCodeFiles(entries, "src card", []).every((file) => file.path.startsWith("src/"))).toBe(true);
    expect(rankCodeFiles(entries, "  ", ["src/UserCard.tsx", "missing", "Card.tsx"]).map((file) => file.path)).toEqual(["src/UserCard.tsx", "Card.tsx"]);
    expect(rankCodeFiles(Array.from({ length: 2000 }, (_, index) => ({ path: `src/file-${index}.ts` })), "file", [])).toHaveLength(quickOpenLimit);
    expect(rankCodeFiles(entries, "[not a regex]", [])).toEqual([]);
  });
  it("locates exact original line ranges for CRLF, blank lines, Unicode and large files", () => {
    const text = "first\r\n\r\n😀last\n";
    expect(codeLineRange(text, 1)).toEqual({ start: 0, end: 7 });
    expect(codeLineRange(text, 2)).toEqual({ start: 7, end: 9 });
    expect(codeLineRange(text, 3)).toEqual({ start: 9, end: text.length });
    for (const line of [0, -1, 1.2, 4, NaN]) expect(codeLineRange(text, line)).toBeNull();
    expect(codeLineRange("", 1)).toBeNull();
    const large = "line\n".repeat(10_000);
    expect(codeLineRange(large, 9000)).toEqual({ start: 8999 * 5, end: 9000 * 5 });
    expect(codeLineRange("last line", 1)).toEqual({ start: 0, end: 9 });
  });
  it("extracts bounded declarations while omitting comments and multiline quoted examples", () => {
    const ts = ['// function fake() {}', '/*', 'export class Fake {}', '*/', 'const example = `', 'function fakeInString() {}', '`;', 'export interface Repository {}', 'export function readRepository() {}', 'export const format = (value: string) => value;', 'const caption = "function quoted() {}";'].join("\n");
    expect(codeOutline(ts, "TypeScript")).toEqual([{ name: "Repository", line: 8, kind: "type" }, { name: "readRepository", line: 9, kind: "function" }, { name: "format", line: 10, kind: "function" }]);
    const python = ['example = """', 'def quoted():', '    pass', '"""', 'class Repository:', '    async def read(self):', '        pass'].join("\n");
    expect(codeOutline(python, "Python").map((symbol) => [symbol.name, symbol.line])).toEqual([["Repository", 5], ["read", 6]]);
    expect(codeOutline("func 읽기() {}\nstruct Repository {}", "Swift").map((symbol) => symbol.name)).toEqual(["읽기", "Repository"]);
    expect(codeOutline("a".repeat(300_000), "TypeScript")).toEqual([]);
    expect(codeOutline("export function read() {}\n".repeat(300), "TypeScript")).toHaveLength(codeSymbolLimit);
  });
  it("finds Markdown headings outside fenced and indented code with original line numbers", () => {
    const markdown = "# Overview\n````md\n# Hidden\n```\n# Still hidden\n````\n    # Indented code\n## C#\n### Usage ###\n";
    expect(codeOutline(markdown, "Markdown")).toEqual([{ name: "Overview", line: 1, kind: "heading" }, { name: "C#", line: 8, kind: "heading" }, { name: "Usage", line: 9, kind: "heading" }]);
  });
});
