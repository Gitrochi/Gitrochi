import { describe, expect, it } from "vitest";
import { authorLineFits } from "../src/app/lib/inspector-layout-geometry";

describe("commit inspector author line", () => {
  it.each([0, 10, 17])("keeps the name and the time inside the column with a %i px scrollbar gutter", (gutter) => {
    for (const width of [240, 280, 340]) {
      const content = { left: 16, right: width - gutter - 16 };
      const avatar = { left: content.left, right: content.left + 20 };
      const when = { left: content.right - 44, right: content.right };
      const name = { left: avatar.right + 6, right: when.left - 6 };
      expect(authorLineFits(content, avatar, name, when, 6)).toBe(true);
    }
  });

  it("accepts a short name that leaves room after the time", () => {
    expect(authorLineFits({ left: 16, right: 324 }, { left: 16, right: 36 }, { left: 42, right: 100 }, { left: 106, right: 150 }, 6)).toBe(true);
  });

  it("rejects a time pushed out of the column or under the name", () => {
    const content = { left: 16, right: 264 }, avatar = { left: 16, right: 36 };
    expect(authorLineFits(content, avatar, { left: 42, right: 260 }, { left: 266, right: 310 }, 6)).toBe(false);
    expect(authorLineFits(content, avatar, { left: 42, right: 240 }, { left: 220, right: 264 }, 6)).toBe(false);
  });

  it("rejects a misplaced avatar, a collapsed name or time, and unmeasured boxes", () => {
    const content = { left: 16, right: 264 }, avatar = { left: 16, right: 36 }, when = { left: 220, right: 264 };
    expect(authorLineFits(content, { left: 30, right: 50 }, { left: 56, right: 214 }, when, 6)).toBe(false);
    expect(authorLineFits(content, avatar, { left: 36, right: 214 }, when, 6)).toBe(false);
    expect(authorLineFits(content, avatar, { left: 42, right: 42 }, when, 6)).toBe(false);
    expect(authorLineFits(content, avatar, { left: 42, right: 214 }, { left: 264, right: 264 }, 6)).toBe(false);
    expect(authorLineFits(content, avatar, { left: 42, right: Number.NaN }, when, 6)).toBe(false);
  });
});
