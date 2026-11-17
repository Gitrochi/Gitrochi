import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { laneColors, laneIndex, lanePalette, nodeGap, nodeGapLanes, peoplePalette, personIndex } from "../src/shared/lib/palette";

const read = (path: string) => readFileSync(fileURLToPath(new URL(path, import.meta.url)), "utf8");

// The board's palettes (ComponentsFoundations) and the derived dark values, as docs/design.md lists them
const LINES = { light: ["#1f5a9e", "#1f7a7a", "#a3560f", "#5f6b12", "#2b6d8f", "#5c6068", "#6b4f2a"], dark: ["#66a1eb", "#5baeae", "#da884b", "#99a755", "#67a7cc", "#9a9ea6", "#b89872"] };
// the teal tint is lifted from the board's #e5f2f2 so the lane's text reaches 4.5:1 on it
const TINTS = { light: ["#eaf0fa", "#e7f4f4", "#f9ece0", "#f0f2e0", "#e6f0f5", "#eeeff1", "#f3ede5"], dark: ["#1f2c3d", "#193030", "#39271a", "#2a2e19", "#1c2e38", "#2a2b2f", "#322a1f"] };
const FILLS = { light: ["#e6e8fa", "#e0f1ec", "#e8eaed", "#f7e4eb"], dark: ["#2c3054", "#113c33", "#30343a", "#4b2636"] };
const LETTERS = { light: ["#3f4bb8", "#1f6b52", "#3a3f47", "#9b3a5f"], dark: ["#b4bbff", "#a5ccbb", "#bec1c7", "#ebadc0"] };
const NODES = ["#4f5bd5", "#2a7d5f", "#4b5563", "#b4466e"];
/** The graph's background: macOS's text background and the Windows surface */
const SURFACES = { light: ["#ffffff"], dark: ["#1e1e1e", "#242427"] };

/** The custom properties of one :root block of global.css */
function tokens(css: string, selector: string): Record<string, string> {
  const start = css.indexOf(`${selector} {`);
  const block = css.slice(start, css.indexOf("\n}", start));
  return Object.fromEntries([...block.matchAll(/(--[\w-]+):\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()]));
}

const css = read("../src/app/styles/global.css");
const light = tokens(css, ":root");
const dark = { ...light, ...tokens(css, ':root[data-theme="dark"]') };
const value = (theme: Record<string, string>, name: string): string => {
  const v = theme[name];
  return v?.startsWith("var(") ? value(theme, v.slice(4, -1)) : v;
};

function luminance(hex: string) {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
const contrast = (a: string, b: string) => {
  const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
};
function oklab(hex: string) {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  const [l, m, s] = [0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b].map(Math.cbrt);
  return [0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s, 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s, 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s];
}
const distance = (a: string, b: string) => Math.hypot(...oklab(a).map((v, i) => v - oklab(b)[i]));

/** Theme.swift's `(0xaaaaaa, 0xbbbbbb)` pairs after a table's name, as #hex strings */
function swiftTable(swift: string, name: string): string[][] {
  const start = swift.indexOf(`static let ${name}:`);
  const body = swift.slice(swift.indexOf("= [", start), swift.indexOf("\n    ]", start));
  return [...body.matchAll(/\(([^()]*(?:\([^()]*\)[^()]*)*)\)/g)].map((m) => [...m[1].matchAll(/0x([0-9a-f]{6})/g)].map((h) => `#${h[1]}`));
}

describe("the fixed palettes", () => {
  it("keeps the board's lanes in order with their tints, and the derived dark set", () => {
    expect(lanePalette.map((_, i) => light[`--lane-${i}`])).toEqual(LINES.light);
    expect(lanePalette.map((_, i) => light[`--lane-${i}-tint`])).toEqual(TINTS.light);
    expect(lanePalette.map((_, i) => dark[`--lane-${i}`])).toEqual(LINES.dark);
    expect(lanePalette.map((_, i) => dark[`--lane-${i}-tint`])).toEqual(TINTS.dark);
    // a filled chip: white in light, the lane's own tint in dark
    expect(lanePalette.map((_, i) => value(light, `--lane-${i}-on`))).toEqual(LINES.light.map(() => "#ffffff"));
    expect(lanePalette.map((_, i) => value(dark, `--lane-${i}-on`))).toEqual(TINTS.dark);
  });

  it("keeps the board's people, with derived dark avatars and the same node colours", () => {
    expect(peoplePalette.map((_, i) => [light[`--person-${i}-fill`], light[`--person-${i}-letter`], light[`--person-${i}-node`]])).toEqual(NODES.map((node, i) => [FILLS.light[i], LETTERS.light[i], node]));
    expect(peoplePalette.map((_, i) => [dark[`--person-${i}-fill`], dark[`--person-${i}-letter`], dark[`--person-${i}-node`]])).toEqual(NODES.map((node, i) => [FILLS.dark[i], LETTERS.dark[i], node]));
  });

  it("is the same on macOS", () => {
    const swift = read("../../macos/Sources/Views/Shared/Theme.swift");
    expect(swiftTable(swift, "lineValues")).toEqual(LINES.light.map((l, i) => [l, LINES.dark[i]]));
    expect(swiftTable(swift, "tintValues")).toEqual(TINTS.light.map((t, i) => [t, TINTS.dark[i]]));
    expect(swiftTable(swift, "personValues")).toEqual(NODES.map((node, i) => [FILLS.light[i], FILLS.dark[i], LETTERS.light[i], LETTERS.dark[i], node]));
    expect(swift).toContain("static let nodeGapLanes: [(light: Set<Int>, dark: Set<Int>)] = [([], []), ([1], []), ([5], []), ([], [])]");
    expect(nodeGapLanes).toEqual([{ light: [], dark: [] }, { light: [1], dark: [] }, { light: [5], dark: [] }, { light: [], dark: [] }]);
  });

  it("reads well on both themes", () => {
    for (const theme of ["light", "dark"] as const) {
      LINES[theme].forEach((line, i) => {
        // a line keeps 3:1 on the graph, and a chip's text 4.5:1 on its tint and on the filled chip
        for (const surface of SURFACES[theme]) expect(contrast(line, surface), `${theme} lane ${i} on ${surface}`).toBeGreaterThanOrEqual(3);
        expect(contrast(line, TINTS[theme][i]), `${theme} lane ${i} on its tint`).toBeGreaterThanOrEqual(4.5);
        expect(contrast(theme === "light" ? "#ffffff" : TINTS.dark[i], line), `${theme} filled chip ${i}`).toBeGreaterThanOrEqual(4.5);
      });
      FILLS[theme].forEach((fill, i) => expect(contrast(LETTERS[theme][i], fill), `${theme} initial ${i}`).toBeGreaterThanOrEqual(4.5));
    }
    NODES.forEach((node, i) => expect(contrast("#ffffff", node), `white on node ${i}`).toBeGreaterThanOrEqual(4.5));
  });

  it("separates a node from a lane ring of nearly its colour with a gap, in the theme where they are close", () => {
    const close = (theme: "light" | "dark") => NODES.map((node) => LINES[theme].flatMap((line, lane) => (distance(node, line) < 0.07 ? [lane] : [])));
    expect(nodeGapLanes.map((g) => g.light)).toEqual(close("light"));
    expect(nodeGapLanes.map((g) => g.dark)).toEqual(close("dark"));
    // Sam's green on the teal lane, as the board shows it, and Morgan's slate on the grey lane
    expect(nodeGap(1, 1)).toBe("light");
    expect(nodeGap(2, 5)).toBe("light");
    expect(nodeGap(2, 12)).toBe("light");
    expect(nodeGap(0, 0)).toBe("");
  });

  it("wraps lanes round the palette", () => {
    expect(laneIndex(7)).toBe(0);
    expect(laneIndex(-1)).toBe(6);
    expect(laneColors(9)).toBe(laneColors(2));
    expect(laneColors(2)).toEqual({ line: "var(--lane-2)", tint: "var(--lane-2-tint)", onLine: "var(--lane-2-on)", selected: "color-mix(in srgb, var(--lane-2) 40%, transparent)" });
  });

  it("picks a person's colour from the e-mail, the same way on both platforms and whatever its case", () => {
    // pinned: macos/Tools/test-graph-palette.sh checks the same addresses
    expect(["alex@example.com", "sam@example.com", "morgan@example.com", "jordan@example.com", "demo-alex", "look-1", "look-2", "look-3"].map(personIndex)).toEqual([0, 3, 2, 0, 1, 0, 1, 2]);
    expect(personIndex("Alex@Example.COM")).toBe(personIndex("alex@example.com"));
  });
});
