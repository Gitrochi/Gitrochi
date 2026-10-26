import { describe, expect, it } from "vitest";
import { authorFillsIdentityColumn } from "../src/app/lib/inspector-layout-geometry";

describe("compact inspector author column", () => {
  it.each([0, 10, 17])("fills the available card width with a %i px scrollbar gutter", (gutter) => {
    for (const width of [240, 280, 320]) {
      const identity = { left: -9975, right: -10000 + width - gutter - 25 };
      const avatar = { left: identity.left, right: identity.left + 34 };
      const author = { left: avatar.right + 10, right: identity.right };
      expect(authorFillsIdentityColumn(identity, avatar, author, 10)).toBe(true);
    }
  });

  it("rejects a date or other sibling stealing width from the author", () => {
    expect(authorFillsIdentityColumn({ left: 25, right: 205 }, { left: 25, right: 59 }, { left: 69, right: 165 }, 10)).toBe(false);
  });

  it("rejects overflow, overlap and collapsed author columns", () => {
    const identity = { left: 25, right: 205 }, avatar = { left: 25, right: 59 };
    expect(authorFillsIdentityColumn(identity, avatar, { left: 69, right: 215 }, 10)).toBe(false);
    expect(authorFillsIdentityColumn(identity, avatar, { left: 59, right: 205 }, 10)).toBe(false);
    expect(authorFillsIdentityColumn(identity, avatar, { left: 69, right: 69 }, 10)).toBe(false);
    expect(authorFillsIdentityColumn(identity, avatar, { left: 69, right: Number.NaN }, 10)).toBe(false);
    expect(authorFillsIdentityColumn(identity, { left: 45, right: 79 }, { left: 89, right: 205 }, 10)).toBe(false);
  });
});
