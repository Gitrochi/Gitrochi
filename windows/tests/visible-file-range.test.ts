import { describe, expect, it } from "vitest";
import { visibleFileRange } from "../src/widgets/inspector/lib/visible-file-range";

describe("file list viewport bounds", () => {
  const files = Array.from({ length: 1000 }, (_, id) => id);
  it("keeps the first render virtual while a pane still has its full content height", () => {
    const range = visibleFileRange(files.length, 0, files.length * 28, 1080);
    const rendered = files.slice(range.first, range.last);
    expect(rendered[0]).toBe(0);
    expect(rendered.length).toBeGreaterThanOrEqual(Math.ceil(1080 / 28));
    expect(rendered.length).toBeLessThan(100);
  });
  it("uses the smaller measured pane after shared heights settle", () => {
    const temporary = visibleFileRange(files.length, 0, files.length * 28, 1080);
    const settled = visibleFileRange(files.length, 0, 218, 1080);
    expect(settled.first).toBe(0);
    expect(settled.last).toBeLessThan(temporary.last);
    expect(settled.last).toBeGreaterThanOrEqual(Math.ceil(218 / 28));
  });
  it("still renders the final file after scrolling to the bottom of a settled pane", () => {
    const paneHeight = 218, offset = files.length * 28 - paneHeight;
    const range = visibleFileRange(files.length, offset, paneHeight, 1080);
    const rendered = files.slice(range.first, range.last);
    expect(rendered.at(-1)).toBe(999);
    expect(rendered.length).toBeLessThan(100);
    expect(range.first).toBeLessThanOrEqual(Math.floor(offset / 28));
  });
  it("retains every natural-pane row when the outer page owns scrolling", () => {
    const range = visibleFileRange(files.length, 0, files.length * 28, 1080, false);
    const rendered = files.slice(range.first, range.last);
    expect(rendered).toHaveLength(1000);
    expect(rendered.at(-1)).toBe(999);
  });
  it("retains a bounded fallback before the document has a measurable viewport", () => {
    const range = visibleFileRange(files.length, 0, files.length * 28, 0);
    expect(range.first).toBe(0);
    expect(range.last).toBeGreaterThan(0);
    expect(range.last).toBeLessThan(100);
    expect(visibleFileRange(0, 0, 218, 1080)).toEqual({ first: 0, last: 0 });
  });
});
