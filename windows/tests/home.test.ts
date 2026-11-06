import { describe, expect, it } from "vitest";
import type { ProjectPortfolioTask } from "@/entities/hosting";
import { homeChanged, homeMatches, homeOpened, homeSync, homeTodayTasks } from "@/widgets/workspace-panels/model/home";

const task = (title: string, due: string | null, extra: Partial<ProjectPortfolioTask["entry"]> = {}): ProjectPortfolioTask =>
  ({ id: title, projectNames: ["Website"], detail: {}, entry: { row: { id: title, title }, due, start: null, date: due, completed: false, invalidDate: false, invalidRange: false, ...extra } }) as unknown as ProjectPortfolioTask;

describe("Home", () => {
  it("says what is not pushed and what is to pull, or that the repository is up to date", () => {
    expect(homeSync(2, 0)).toBe("2 not pushed");
    expect(homeSync(1, 3)).toBe("1 not pushed · 3 to pull");
    expect(homeSync(0, 0)).toBe("Up to date");
  });

  it("names today and yesterday and dates the rest, with the year only for another year", () => {
    const now = new Date(2026, 10, 5, 9).getTime();
    expect(homeOpened(new Date(2026, 10, 5, 1).getTime(), now, "en")).toBe("Today");
    expect(homeOpened(new Date(2026, 10, 4, 23).getTime(), now, "en")).toBe("Yesterday");
    expect(homeOpened(new Date(2026, 9, 29).getTime(), now, "en")).toBe("Oct 29");
    expect(homeOpened(new Date(2025, 11, 30).getTime(), now, "en")).toBe("Dec 30, 2025");
  });

  it("filters by any part of the path and counts each changed file once", () => {
    expect(homeMatches("C:/Projects/design-tokens", " TOKENS ")).toBe(true);
    expect(homeMatches("C:/Projects/design-tokens", "website")).toBe(false);
    expect(homeMatches("C:/Projects/design-tokens", "  ")).toBe(true);
    const file = (path: string) => ({ path }) as never;
    expect(homeChanged({ branch: "main", upstream: null, ahead: 0, behind: 0, staged: [file("a")], unstaged: [file("a"), file("b")], conflicted: [] })).toBe(2);
  });

  it("lists at most five tasks, overdue first and oldest first, then today's; done and undated ones are left out", () => {
    const today = "2026-11-05";
    const rows = homeTodayTasks([
      task("Today B", today), task("Later", "2026-11-09"), task("Overdue new", "2026-11-03"), task("Done", "2026-11-01", { completed: true }),
      task("Overdue old", "2026-10-30"), task("No date", null), task("Today A", today), task("Today C", today), task("Today D", today),
    ], today);
    expect(rows.map((row) => row.entry.row.title)).toEqual(["Overdue old", "Overdue new", "Today A", "Today B", "Today C"]);
  });
});
