/**
 * Panes stacked in one column share its height: each gets its natural height when that fits, and the long ones split what
 * is left (water-fill). None goes under the floor, even if the column then has to scroll. (macOS: Views/Shared/SharedStack.swift)
 */
export function shareHeights(naturals: number[], available: number, floor: number): number[] {
  const out = naturals.map((n) => Math.min(n, floor));
  let left = available - out.reduce((a, b) => a + b, 0);
  let pending = naturals.map((_, i) => i).filter((i) => naturals[i] > out[i]);
  while (left > 0 && pending.length) {
    const fair = left / pending.length;
    const done = pending.filter((i) => naturals[i] - out[i] <= fair);
    if (!done.length) {
      for (const i of pending) out[i] += fair;
      break;
    }
    for (const i of done) {
      left -= naturals[i] - out[i];
      out[i] = naturals[i];
    }
    pending = pending.filter((i) => !done.includes(i));
  }
  return out.map((h) => Math.floor(h));
}
