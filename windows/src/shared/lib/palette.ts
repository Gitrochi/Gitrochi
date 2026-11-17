/**
 * The redesign board's fixed lane palette (ComponentsFoundations), never the accent. The values are the --lane-* tokens
 * in app/styles/global.css, the board's in light and each hue lifted in dark (docs/design.md, Commit graph). Views take
 * these prepared strings, so nothing is worked out per row. macOS: Palette in Views/Shared/Theme.swift
 */

/** A lane: its line, the tint behind it (the band, a chip), the text on a chip filled with the line, and the selected commit's band (the line at 40%) */
export interface LaneColors {
  line: string;
  tint: string;
  onLine: string;
  selected: string;
}

export const lanePalette: LaneColors[] = Array.from({ length: 7 }, (_, i) => ({
  line: `var(--lane-${i})`,
  tint: `var(--lane-${i}-tint)`,
  onLine: `var(--lane-${i}-on)`,
  selected: `color-mix(in srgb, var(--lane-${i}) 40%, transparent)`,
}));

/** The layout numbers lanes on, so they wrap round the palette */
export const laneIndex = (i: number) => ((i % lanePalette.length) + lanePalette.length) % lanePalette.length;

export const laneColors = (i: number): LaneColors => lanePalette[laneIndex(i)];
