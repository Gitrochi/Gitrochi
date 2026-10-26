import { describe, expect, it } from "vitest";
import { pastedImageName, shellPath } from "@/entities/terminal/lib/paths";

describe("paths typed into the terminal", () => {
  it("quotes only when the shell would split or expand", () => {
    expect(shellPath("C:\\work\\a.png", false)).toBe("C:\\work\\a.png");
    expect(shellPath("C:\\My Work\\a.png", false)).toBe('"C:\\My Work\\a.png"');
    expect(shellPath("C:\\work\\a&b.png", false)).toBe('"C:\\work\\a&b.png"');
  });

  it("gives a WSL shell the /mnt path", () => {
    expect(shellPath("C:\\My Work\\a.png", true)).toBe('"/mnt/c/My Work/a.png"');
    expect(shellPath("\\\\wsl.localhost\\Ubuntu\\home\\me\\a.png", true)).toBe("/home/me/a.png");
  });

  it("names a pasted image by time, keeps a dropped file's name", () => {
    const at = new Date("2026-10-26T13:51:44Z");
    expect(pastedImageName({ name: "image.png", type: "image/png" }, at)).toBe("gitrochi-image-20261026-135144.png");
    expect(pastedImageName({ name: "", type: "image/jpeg" }, at, "-2")).toBe("gitrochi-image-20261026-135144-2.jpg");
    expect(pastedImageName({ name: "shot.png", type: "image/png" }, at)).toBe("shot.png");
  });
});
