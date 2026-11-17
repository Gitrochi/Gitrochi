import { stableHash } from "./format";

/**
 * The redesign board's fixed palettes (ComponentsFoundations): the graph's lanes and the colours of a person without a
 * photo, never the accent. The values are the --lane-* and --person-* tokens in app/styles/global.css, the board's in
 * light and each hue lifted in dark (docs/design.md, Commit graph). Views take these prepared strings, so nothing is
 * worked out per row. macOS: Palette in Views/Shared/Theme.swift
 */

/** A lane: its line, the tint behind it (the band, a chip), the text on a chip filled with the line, and the selected commit's band (the line at 35%: the board's 40% left teal and amber lines under 3:1 on it) */
export interface LaneColors {
  line: string;
  tint: string;
  onLine: string;
  selected: string;
}

/** A person without a photo: the avatar's fill and letter, and a graph node's fill under a white letter */
export interface PersonColors {
  fill: string;
  letter: string;
  node: string;
}

export const lanePalette: LaneColors[] = Array.from({ length: 7 }, (_, i) => ({
  line: `var(--lane-${i})`,
  tint: `var(--lane-${i}-tint)`,
  onLine: `var(--lane-${i}-on)`,
  selected: `color-mix(in srgb, var(--lane-${i}) 35%, transparent)`,
}));

export const peoplePalette: PersonColors[] = Array.from({ length: 4 }, (_, i) => ({
  fill: `var(--person-${i}-fill)`,
  letter: `var(--person-${i}-letter)`,
  node: `var(--person-${i}-node)`,
}));

/**
 * The lanes where a person's node colour is within 0.07 of the lane in OKLab, too close to tell fill and ring apart, so
 * a 2px surface gap separates them (the board shows Sam on the teal lane). The dark lanes are far enough. [person] → lanes
 */
export const nodeGapLanes: { light: number[]; dark: number[] }[] = [
  { light: [], dark: [] },
  { light: [1], dark: [] },
  { light: [5], dark: [] },
  { light: [], dark: [] },
];

/** [person][lane]: the themes that need the gap, as the avatar's data-gap ("light", "dark", both or none) */
const nodeGaps: string[][] = nodeGapLanes.map((gap) =>
  lanePalette.map((_, lane) => [gap.light.includes(lane) ? "light" : "", gap.dark.includes(lane) ? "dark" : ""].filter(Boolean).join(" ")),
);

/** The layout numbers lanes on, so they wrap round the palette */
export const laneIndex = (i: number) => ((i % lanePalette.length) + lanePalette.length) % lanePalette.length;

export const laneColors = (i: number): LaneColors => lanePalette[laneIndex(i)];

/** The person an e-mail (or a login) is drawn as: the same on every run and on both platforms */
export const personIndex = (email: string) => stableHash(email.toLowerCase()) % peoplePalette.length;

export const nodeGap = (person: number, lane: number) => nodeGaps[person][laneIndex(lane)];
