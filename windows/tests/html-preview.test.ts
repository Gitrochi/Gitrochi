import { describe, expect, it } from "vitest";
import { createPreviewBudget, htmlPreviewCSP, previewAssetPath, previewEmbeddedCharacters, previewReferenceLimit, safePreviewImage } from "../src/widgets/local-workbench/lib/html-preview";

describe("isolated HTML preview", () => {
  it("resolves local assets within the immutable tree without URL or traversal escapes", () => {
    expect(previewAssetPath("pages/index.html", "styles/site.css?v=2#top")).toBe("pages/styles/site.css");
    expect(previewAssetPath("pages/styles/site.css", "../images/a%20b.png")).toBe("pages/images/a b.png");
    expect(previewAssetPath("pages/index.html", "/assets/pixel.png")).toBe("assets/pixel.png");
    for (const value of ["https://example.invalid/a.css", "//example.invalid/a.css", "file:///private/file", "javascript:alert(1)", "data:text/html,x", "../../secret.png", "..\\secret.png", "%00a.css", "#anchor", "%zz"]) expect(previewAssetPath("pages/index.html", value)).toBeNull();
  });
  it("admits only bounded raster data URLs with the matching image signature", () => {
    const png = "data:image/png;base64," + btoa(String.fromCharCode(137, 80, 78, 71, 13, 10, 26, 10));
    expect(safePreviewImage(png)).toBe(png);
    expect(safePreviewImage(png.replace("image/png", "image/jpeg"))).toBeNull();
    expect(safePreviewImage("data:image/svg+xml;base64," + btoa('<svg onload="alert(1)"></svg>'))).toBeNull();
    expect(safePreviewImage("https://example.invalid/image.png")).toBeNull();
    expect(safePreviewImage("data:image/png;base64,!!!!")).toBeNull();
    expect(htmlPreviewCSP).toContain("script-src 'none'");
    expect(htmlPreviewCSP).toContain("connect-src 'none'");
    expect(htmlPreviewCSP).toContain("form-action 'none'");
  });
  it("caps repeated references and emitted content even when every reference shares one cached asset", () => {
    const budget = createPreviewBudget();
    for (let i = 0; i < previewReferenceLimit; i++) expect(budget.reference()).toBe(true);
    expect(budget.reference()).toBe(false);
    const shared = "x".repeat(1_000_000);
    for (let i = 0; i < previewEmbeddedCharacters / shared.length; i++) expect(budget.embed(shared)).toBe(shared);
    expect(budget.embed(shared)).toBeNull();
  });
  it("escapes CSS raw-text closing tags and charges escape growth before allocating output", () => {
    const budget = createPreviewBudget(), malicious = '</style><meta http-equiv="refresh" content="0;url=https://example.invalid">';
    expect(budget.style(malicious)).not.toContain("<");
    expect(budget.style("<".repeat(previewEmbeddedCharacters / 4 + 1))).toBeNull();
  });
});
