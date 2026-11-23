import { describe, expect, it } from "vitest";
import { dateTimePresets, minutesOfDay, monthGrid, timeSlots, withDay, withMinutes } from "../src/shared/lib/calendar";

describe("date and time field arithmetic", () => {
  it("lays a month out in six weeks from the first weekday", () => {
    const sundays = monthGrid(2026, 10, 0); // November 2026 starts on a Sunday
    expect(sundays).toHaveLength(42);
    expect(sundays[0]).toMatchObject({ day: 1, inMonth: true });
    expect(sundays.filter((d) => d.inMonth)).toHaveLength(30);
    const mondays = monthGrid(2026, 10, 1);
    expect(mondays[0]).toMatchObject({ day: 26, inMonth: false });
    expect(mondays[6]).toMatchObject({ day: 1, inMonth: true });
  });
  it("moves a moment to another day or time without touching the rest", () => {
    const at = new Date(2026, 10, 23, 14, 30).getTime();
    expect(new Date(withDay(at, new Date(2026, 11, 2).getTime()))).toEqual(new Date(2026, 11, 2, 14, 30));
    expect(new Date(withMinutes(at, 9 * 60 + 15))).toEqual(new Date(2026, 10, 23, 9, 15));
    expect(minutesOfDay(at)).toBe(870);
    expect(timeSlots(15)).toHaveLength(96);
    expect(timeSlots(30).at(-1)).toBe(1410);
  });
  it("offers an hour from now, tonight only while it is ahead, and tomorrow morning", () => {
    const afternoon = new Date(2026, 10, 23, 14, 7).getTime();
    expect(dateTimePresets(afternoon).map((p) => [p.id, new Date(p.at).toString()])).toEqual([
      ["hour", new Date(2026, 10, 23, 15, 10).toString()],
      ["tonight", new Date(2026, 10, 23, 21, 0).toString()],
      ["tomorrow", new Date(2026, 10, 24, 9, 0).toString()],
    ]);
    expect(dateTimePresets(new Date(2026, 10, 30, 22, 0).getTime()).map((p) => p.id)).toEqual(["hour", "tomorrow"]);
    expect(new Date(dateTimePresets(new Date(2026, 10, 30, 22, 0).getTime())[1].at)).toEqual(new Date(2026, 11, 1, 9, 0));
  });
});
