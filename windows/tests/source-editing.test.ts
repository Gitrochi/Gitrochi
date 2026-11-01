import { describe, expect, it } from "vitest";
import { applyEditorText, editorLineRange, editorText, indentEditorText } from "../src/shared/lib/source-editing";

describe("source editor text operations", () => {
  it("keeps a no-op byte-for-byte and retains the BOM and untouched mixed line endings", () => {
    const original = "\uFEFFfirst\r\nsecond\nthird\r\n";
    expect(applyEditorText(original, editorText(original))).toBe(original);
    expect(applyEditorText(original, "first\nchanged\nthird\n")).toBe("\uFEFFfirst\r\nchanged\nthird\r\n");
  });

  it("uses the file's CRLF style for inserted lines without rewriting its other bytes", () => {
    expect(applyEditorText("\uFEFFa\r\nb\r\n", "a\nnew\nb\n")).toBe("\uFEFFa\r\nnew\r\nb\r\n");
    expect(applyEditorText("a\r\nb", "ab")).toBe("ab");
    expect(applyEditorText("x😀\r\ny", "x😃\ny")).toBe("x😃\r\ny");
  });

  it("indents and outdents a selected block without touching the next unselected line", () => {
    const before = "one\ntwo\nthree\n";
    const indented = indentEditorText(before, 0, 8, false);
    expect(indented.text).toBe("  one\n  two\nthree\n");
    expect(indentEditorText(indented.text, indented.start, indented.end, true).text).toBe(before);
  });

  it("handles blank first lines and caret indentation without deleting source characters", () => {
    expect(indentEditorText("\nnext", 0, 0, false)).toEqual({ text: "  \nnext", start: 2, end: 2 });
    expect(indentEditorText("  code", 2, 2, true)).toEqual({ text: "code", start: 0, end: 0 });
    expect(indentEditorText("code", 1, 1, false)).toEqual({ text: "c  ode", start: 3, end: 3 });
  });

  it("locates logical lines for go-to-line without changing text", () => {
    expect(editorLineRange("first\nsecond\n", 2)).toEqual({ start: 6, end: 12 });
    expect(editorLineRange("first\n", 2)).toEqual({ start: 6, end: 6 });
  });
});
