/**
 * The arithmetic behind the date and time field: a month's grid of days, the times of day to pick from, and a few
 * ready-made moments. Local time throughout. (macOS: Core/CalendarGrid.swift)
 */

export interface CalendarDay { at: number; day: number; inMonth: boolean }

/** Midnight of the day `at` falls on */
export function startOfDay(at: number): number {
  const d = new Date(at);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/**
 * Six weeks of days covering `month` (0-11) of `year`, starting on `firstWeekday` (0 Sunday … 6 Saturday), so the grid
 * keeps its height from month to month
 */
export function monthGrid(year: number, month: number, firstWeekday = 0): CalendarDay[] {
  const first = new Date(year, month, 1);
  const lead = (first.getDay() - firstWeekday + 7) % 7;
  return Array.from({ length: 42 }, (_, i) => {
    const d = new Date(year, month, 1 - lead + i);
    return { at: d.getTime(), day: d.getDate(), inMonth: d.getMonth() === month };
  });
}

/** Minutes after midnight, every `step` minutes */
export function timeSlots(step = 15): number[] {
  return Array.from({ length: Math.floor(1440 / step) }, (_, i) => i * step);
}

/** `at` moved to another day, keeping its time of day */
export function withDay(at: number, day: number): number {
  const time = new Date(at), d = new Date(day);
  d.setHours(time.getHours(), time.getMinutes(), 0, 0);
  return d.getTime();
}

/** `at` at another time of the same day */
export function withMinutes(at: number, minutes: number): number {
  const d = new Date(at);
  d.setHours(Math.floor(minutes / 60), minutes % 60, 0, 0);
  return d.getTime();
}

export const minutesOfDay = (at: number): number => { const d = new Date(at); return d.getHours() * 60 + d.getMinutes(); };

export type DateTimePreset = { id: "hour" | "tonight" | "tomorrow"; at: number };

/** In an hour (rounded up to five minutes), tonight at 21:00 while that is ahead, tomorrow at 9:00 */
export function dateTimePresets(now: number): DateTimePreset[] {
  const five = 5 * 60_000;
  const hour = Math.ceil((now + 3_600_000) / five) * five;
  const tonight = withMinutes(now, 21 * 60);
  const tomorrow = withMinutes(new Date(startOfDay(now)).setDate(new Date(now).getDate() + 1), 9 * 60);
  return [{ id: "hour", at: hour }, ...(tonight > now ? [{ id: "tonight" as const, at: tonight }] : []), { id: "tomorrow", at: tomorrow }];
}
