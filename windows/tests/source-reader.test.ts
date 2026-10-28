import { describe, expect, it } from "vitest";
import { sourceLanguage, sourceLineCount, sourceMatches, sourceMatchLimit, sourceTokens, syntaxCharacterLimit, syntaxTokenLimit } from "../src/widgets/local-workbench/lib/source-reader";

describe("source reader", () => {
  it("identifies source languages without interpreting unknown files as code", () => {
    expect(sourceLanguage("Sources/Window.SWIFT")).toBe("Swift");
    expect(sourceLanguage("src/Card.tsx")).toBe("TypeScript JSX");
    expect(sourceLanguage("assets/file.unknown")).toBe("Plain text");
  });
  it("keeps comments and escaped strings intact instead of coloring their contents as keywords", () => {
    const text = 'const value = "return \\"quoted\\""; // let value = 42\n/* async\nreturn */';
    const tokens = sourceTokens(text, "TypeScript");
    expect(tokens.filter((token) => token.kind === "keyword").map((token) => text.slice(token.start, token.end))).toEqual(["const"]);
    expect(tokens.filter((token) => token.kind === "comment").map((token) => text.slice(token.start, token.end))).toEqual(["// let value = 42", "/* async\nreturn */"]);
    expect(tokens.every((token, i) => token.start < token.end && (!i || tokens[i - 1].end <= token.start))).toBe(true);
  });
  it("handles hash comments only in the languages that use them", () => {
    const text = 'value = "# not a comment" # return 5';
    const tokens = sourceTokens(text, "Python");
    expect(tokens.filter((token) => token.kind === "comment").map((token) => text.slice(token.start, token.end))).toEqual(["# return 5"]);
    expect(sourceTokens("const #field = 1;", "JavaScript").some((token) => token.kind === "comment")).toBe(false);
  });
  it("searches literal punctuation, repeated matches, CRLF and Unicode using original offsets", () => {
    const text = "İbefore [a.*] 😀\r\nAFTER [A.*] 😀";
    const matches = sourceMatches(text, "[a.*]");
    expect(matches.map((match) => text.slice(match.start, match.end))).toEqual(["[a.*]", "[A.*]"]);
    expect(sourceMatches(text, "AFTER")).toEqual([{ start: text.indexOf("AFTER"), end: text.indexOf("AFTER") + 5 }]);
    expect(sourceMatches(text, "😀").map((match) => text.slice(match.start, match.end))).toEqual(["😀", "😀"]);
    expect(sourceMatches(text, "")).toEqual([]);
    expect(sourceMatches("aaaa", "aa")).toEqual([{ start: 0, end: 2 }, { start: 2, end: 4 }]);
  });
  it("bounds rendering work on large files and dense search results while preserving source", () => {
    expect(sourceTokens("a".repeat(syntaxCharacterLimit + 1), "Swift")).toEqual([]);
    expect(sourceTokens("const ".repeat(syntaxTokenLimit), "TypeScript")).toEqual([]);
    const text = "x".repeat(2_000_000), matches = sourceMatches(text, "x");
    expect(matches).toHaveLength(sourceMatchLimit);
    expect(matches.at(-1)).toEqual({ start: sourceMatchLimit - 1, end: sourceMatchLimit });
    expect(text.length).toBe(2_000_000);
  });
  it("counts actual lines without adding an extra line for the final newline", () => {
    expect(["", "one", "one\n", "one\r\ntwo\r\n", "\n\n"].map(sourceLineCount)).toEqual([0, 1, 1, 2, 2]);
  });
});
