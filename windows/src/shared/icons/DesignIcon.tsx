import type { LucideIcon, LucideProps } from "lucide-react";

/**
 * The redesign's own icons, drawn on a 16px grid with a 1.5px stroke. The same drawings are in
 * macos/Sources/Views/Shared/DesignIcon.swift: change both together.
 */
const drawings = {
  account: "<circle cx=\"8\" cy=\"8\" r=\"6.5\"/><circle cx=\"8\" cy=\"6.6\" r=\"2.1\"/><path d=\"M4 12.6c.9-1.6 2.3-2.4 4-2.4s3.1.8 4 2.4\"/>",
  home: "<path d=\"M2.5 7.2 8 2.8l5.5 4.4\"/><path d=\"M4 6.2V13h3v-3.2h2V13h3V6.2\"/>",
  repository: "<path d=\"M1.8 4.2a1 1 0 0 1 1-1h3.1l1.4 1.5h5.9a1 1 0 0 1 1 1v6.6a1 1 0 0 1-1 1H2.8a1 1 0 0 1-1-1z\"/>",
  compare: "<path d=\"M2.5 5.5h10M10 3l2.5 2.5L10 8\"/><path d=\"M13.5 10.5h-10M6 8l-2.5 2.5L6 13\"/>",
  rebase: "<circle cx=\"3.2\" cy=\"4\" r=\"1\"/><circle cx=\"3.2\" cy=\"8\" r=\"1\"/><circle cx=\"3.2\" cy=\"12\" r=\"1\"/><path d=\"M6.5 4h7M6.5 8h7M6.5 12h7\"/>",
  code: "<path d=\"M5.5 4.5 2 8l3.5 3.5M10.5 4.5 14 8l-3.5 3.5M9.2 3 6.8 13\"/>",
  pullRequests: "<circle cx=\"4.5\" cy=\"3.5\" r=\"1.5\"/><circle cx=\"4.5\" cy=\"12.5\" r=\"1.5\"/><circle cx=\"11.5\" cy=\"12.5\" r=\"1.5\"/><path d=\"M4.5 5v6M11.5 11V6.5a2 2 0 0 0-2-2H7.5M9 3 7.5 4.5 9 6\"/>",
  issues: "<circle cx=\"8\" cy=\"8\" r=\"6\"/><circle cx=\"8\" cy=\"8\" r=\"1.4\"/>",
  actions: "<circle cx=\"8\" cy=\"8\" r=\"6\"/><path d=\"M6.8 5.6v4.8l3.8-2.4z\"/>",
  releases: "<path d=\"M2.5 2.5h5.2l6 6-5.2 5.2-6-6z\"/><circle cx=\"5.4\" cy=\"5.4\" r=\"0.8\"/>",
  projects: "<rect x=\"2\" y=\"3\" width=\"12\" height=\"10\" rx=\"1.5\"/><path d=\"M6 3v10M10 3v10\"/>",
  flows: "<rect x=\"2\" y=\"2.5\" width=\"4.5\" height=\"3.5\" rx=\"1\"/><rect x=\"9.5\" y=\"10\" width=\"4.5\" height=\"3.5\" rx=\"1\"/><path d=\"M4.2 6v4.2a1.5 1.5 0 0 0 1.5 1.5h3.8\"/>",
  ledger: "<path d=\"M2.5 4.4l1.3 1.3L6.2 3.2M2.5 10.4l1.3 1.3 2.4-2.5M8.5 4.6h5M8.5 10.6h5\"/>",
  settings: "<circle cx=\"8\" cy=\"8\" r=\"2.2\"/><path d=\"M8 1.8v1.6M8 12.6v1.6M1.8 8h1.6M12.6 8h1.6M3.6 3.6l1.1 1.1M11.3 11.3l1.1 1.1M3.6 12.4l1.1-1.1M11.3 4.7l1.1-1.1\"/>",
  chevronDown: "<path d=\"M4 6l4 4 4-4\"/>",
  chevronUp: "<path d=\"M4 10l4-4 4 4\"/>",
  chevronLeft: "<path d=\"M10 3.5 5.5 8l4.5 4.5\"/>",
  chevronRight: "<path d=\"M6 3.5 10.5 8 6 12.5\"/>",
  commit: "<circle cx=\"8\" cy=\"8\" r=\"2.5\"/><path d=\"M1.5 8h4M10.5 8h4\"/>",
  branch: "<circle cx=\"4.5\" cy=\"3.5\" r=\"1.5\"/><circle cx=\"4.5\" cy=\"12.5\" r=\"1.5\"/><circle cx=\"11.5\" cy=\"5\" r=\"1.5\"/><path d=\"M4.5 5v6M11.5 6.5c0 3-7 2-7 4.5\"/>",
  refresh: "<path d=\"M13 8a5 5 0 1 1-1.46-3.54\"/><path d=\"M13 2.5V5.5H10\"/>",
  plus: "<path d=\"M8 3v10M3 8h10\"/>",
  terminal: "<rect x=\"1.5\" y=\"2.5\" width=\"13\" height=\"11\" rx=\"2\"/><path d=\"M4.5 6l2 2-2 2M8.5 10.5h3\"/>",
  search: "<circle cx=\"7\" cy=\"7\" r=\"4.5\"/><path d=\"m10.5 10.5 3 3\"/>",
  copy: "<rect x=\"5.5\" y=\"5.5\" width=\"8\" height=\"8\" rx=\"1.5\"/><path d=\"M10.5 5.5v-2a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2\"/>",
  close: "<path d=\"M4.5 4.5l7 7M11.5 4.5l-7 7\"/>",
  check: "<path d=\"m3.5 8.5 3 3 6-7\"/>",
  panelLeft: "<rect x=\"1.5\" y=\"2.5\" width=\"13\" height=\"11\" rx=\"2\"/><path d=\"M6 2.5v11\"/>",
  panelRight: "<rect x=\"1.5\" y=\"2.5\" width=\"13\" height=\"11\" rx=\"2\"/><path d=\"M10 2.5v11\"/>",
  push: "<path d=\"M8 13.5v-10M4 7.5l4-4 4 4\"/>",
  pull: "<path d=\"M8 2.5v10M4 8.5l4 4 4-4\"/>",
  external: "<path d=\"M9 3h4v4M13 3 7.5 8.5M11 9.5V13H3V5h3.5\"/>",
  sort: "<path d=\"M5 3v10M2.5 5.5 5 3l2.5 2.5M11 13V3M8.5 10.5 11 13l2.5-2.5\"/>",
  comment: "<path d=\"M2.5 3.5h11v7.5H7l-3 2.5V11H2.5z\"/>",
  eye: "<path d=\"M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z\"/><circle cx=\"8\" cy=\"8\" r=\"2\"/>",
  sparkles: "<path d=\"M7 2l1.3 3.7L12 7l-3.7 1.3L7 12l-1.3-3.7L2 7l3.7-1.3z\"/><path d=\"M12.5 10.5l.6 1.4 1.4.6-1.4.6-.6 1.4-.6-1.4-1.4-.6 1.4-.6z\"/>",
  file: "<path d=\"M4 1.8h5.2L12 4.6v9.6H4z\"/><path d=\"M9 1.8v3h3\"/>",
  lock: "<rect x=\"3.5\" y=\"7\" width=\"9\" height=\"6.5\" rx=\"1.3\"/><path d=\"M5.5 7V5.2a2.5 2.5 0 0 1 5 0V7\"/>",
  pencil: "<path d=\"M10.5 2.5l3 3L6 13H3v-3z\"/>",
  trash: "<path d=\"M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5\"/>",
  person: "<circle cx=\"8\" cy=\"5.5\" r=\"2.6\"/><path d=\"M3 14c.6-2.8 2.6-4.2 5-4.2s4.4 1.4 5 4.2\"/>",
  clock: "<circle cx=\"8\" cy=\"8\" r=\"6.2\"/><path d=\"M8 4.8V8l2.2 1.6\"/>",
  alert: "<circle cx=\"8\" cy=\"8\" r=\"6.2\"/><path d=\"M8 4.8v3.6M8 11.1v.1\"/>",
  inbox: "<path d=\"M2 9.5 3.8 3.5h8.4L14 9.5v3a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1z\"/><path d=\"M2 9.5h3.2l.8 1.6h4l.8-1.6H14\"/>",
  upFolder: "<path d=\"M13 13H8.5A3.5 3.5 0 0 1 5 9.5V3M2 6l3-3 3 3\"/>",
  whitespace: "<path d=\"M7.5 13V3h5M10.5 3v10M7.5 3H6a2.5 2.5 0 0 0 0 5h1.5\"/>",
  cloud: "<path d=\"M4.6 12.5h7a2.9 2.9 0 0 0 .4-5.8 4 4 0 0 0-7.7.9 2.5 2.5 0 0 0 .3 4.9z\"/>",
  minus: "<path d=\"M3.5 8h9\"/>",
  more: "<circle cx=\"3.5\" cy=\"8\" r=\"1.3\" fill=\"currentColor\" stroke=\"none\"/><circle cx=\"8\" cy=\"8\" r=\"1.3\" fill=\"currentColor\" stroke=\"none\"/><circle cx=\"12.5\" cy=\"8\" r=\"1.3\" fill=\"currentColor\" stroke=\"none\"/>",
  checkCircle: "<circle cx=\"8\" cy=\"8\" r=\"6.2\"/><path d=\"m5.4 8.2 1.8 1.8 3.4-3.8\"/>",
  xCircle: "<circle cx=\"8\" cy=\"8\" r=\"6.2\"/><path d=\"M5.9 5.9l4.2 4.2M10.1 5.9l-4.2 4.2\"/>",
  circle: "<circle cx=\"8\" cy=\"8\" r=\"6.2\"/>",
  merged: "<circle cx=\"4.5\" cy=\"3.5\" r=\"1.5\"/><circle cx=\"4.5\" cy=\"12.5\" r=\"1.5\"/><circle cx=\"11.5\" cy=\"9\" r=\"1.5\"/><path d=\"M4.5 5v6M4.5 5c0 3 3 4 5.5 4\"/>",
  undo: "<path d=\"M5.5 3.5 2.5 6.5l3 3\"/><path d=\"M2.5 6.5h7a3.5 3.5 0 0 1 0 7H7\"/>",
  checkout: "<path d=\"M8 2.5v8M4.5 7 8 10.5 11.5 7M3 13.5h10\"/>",
  link: "<path d=\"M6.5 9.5l3-3M7 4.5l1.2-1.2a2.6 2.6 0 0 1 3.7 3.7L10.7 8.2M9 11.5l-1.2 1.2a2.6 2.6 0 0 1-3.7-3.7L5.3 7.8\"/>",
  globe: "<circle cx=\"8\" cy=\"8\" r=\"6\"/><path d=\"M2 8h12M8 2c1.7 1.8 2.5 3.8 2.5 6S9.7 12.2 8 14C6.3 12.2 5.5 10.2 5.5 8S6.3 3.8 8 2z\"/>",
  key: "<circle cx=\"5\" cy=\"11\" r=\"2.8\"/><path d=\"M7 9l6.5-6.5M11.4 4.6l1.8 1.8M9.6 6.4l1.4 1.4\"/>",
  mic: "<rect x=\"6\" y=\"1.8\" width=\"4\" height=\"8\" rx=\"2\"/><path d=\"M3.5 7.5a4.5 4.5 0 0 0 9 0M8 12v2.3\"/>",
  filter: "<path d=\"M2.5 4h11M4.5 8h7M6.5 12h3\"/>",
  squareCheck: "<rect x=\"2\" y=\"2\" width=\"12\" height=\"12\" rx=\"3\"/><path d=\"m5 8.2 2 2 4-4.4\"/>",
  edit: "<path d=\"M13 9v3.5a1 1 0 0 1-1 1H3.5a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1H7\"/><path d=\"M11.5 2.5l2 2L8 10H6V8z\"/>",
  image: "<rect x=\"2\" y=\"3\" width=\"12\" height=\"10\" rx=\"1.5\"/><circle cx=\"5.8\" cy=\"6.4\" r=\"1.1\"/><path d=\"m2.5 12 3.8-3.6 2.4 2.2 2-1.8 2.8 2.7\"/>",
} as const;

export type DesignIconName = keyof typeof drawings;

/** A component that stands where a lucide icon stood: same size and stroke props, the redesign's drawing */
export function designIcon(name: DesignIconName) {
  return (({ size = 16, strokeWidth = 1.5, absoluteStrokeWidth: _absolute, ...rest }: LucideProps) => (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" aria-hidden {...rest} dangerouslySetInnerHTML={{ __html: drawings[name] }} />
  )) as unknown as LucideIcon;
}
