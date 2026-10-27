import { describe, expect, it, vi } from "vitest";
import type { HubDetail, HubProjectRow } from "@/entities/hosting";
import {
  filterProjectRows,
  projectBranchName,
  projectDateRows,
  projectDateRange,
  runProjectBatch,
  projectFieldValue,
  projectKind,
  projectRepository,
  projectSelectFields,
} from "../src/widgets/hosting-hub/lib/project-workspace";
const row = (values: Partial<HubProjectRow> = {}): HubProjectRow => ({
  id: "issue",
  title: "Fix search",
  body: "Keyboard navigation",
  url: "https://github.com/team/client/issues/42",
  contentID: "ISSUE",
  statuses: { status: "todo" },
  kind: "issue",
  number: 42,
  repository: "team/client",
  assignees: ["reviewer"],
  labels: ["accessibility"],
  ...values,
});
const filters = {
  query: "",
  kind: "",
  repository: "",
  assignee: "",
  archived: false,
};
describe("project workspace", () => {
  it("combines task, repository, assignee and archive filters without hiding unrelated metadata", () => {
    const rows = [
      row(),
      row({ id: "pr", kind: "pullRequest", repository: "team/server" }),
      row({ id: "archived", archived: true }),
    ];
    expect(filterProjectRows(rows, filters).map((item) => item.id)).toEqual([
      "issue",
      "pr",
    ]);
    expect(
      filterProjectRows(rows, {
        ...filters,
        query: "ACCESSIBILITY",
        repository: "team/client",
        assignee: "REVIEWER",
      }).map((item) => item.id),
    ).toEqual(["issue"]);
    expect(
      filterProjectRows(rows, {
        ...filters,
        kind: "issue",
        archived: true,
      }).map((item) => item.id),
    ).toEqual(["issue", "archived"]);
    expect(
      filterProjectRows(rows, { ...filters, query: "nonexistent" }),
    ).toEqual([]);
  });
  it("infers provider task kinds and repositories from older records", () => {
    expect(
      projectKind(
        row({ kind: undefined, url: "https://github.com/team/client/pull/5" }),
      ),
    ).toBe("pullRequest");
    expect(projectRepository(row({ repository: undefined }))).toBe(
      "team/client",
    );
    expect(
      projectRepository(
        row({
          repository: undefined,
          url: "https://gitlab.test/group/nested/client/-/issues/5",
        }),
      ),
    ).toBe("group/nested/client");
    expect(projectKind(row({ kind: undefined, url: "", contentID: "" }))).toBe(
      "redacted",
    );
  });
  it("preserves zero scalar fields, separates grouping fields and sorts only real scheduled dates", () => {
    const date = {
      id: "date",
      name: "Target",
      kind: "date" as const,
      options: [],
    };
    const data = {
      fields: [
        date,
        {
          id: "status",
          name: "Status",
          options: [{ id: "todo", name: "Todo" }],
        },
      ],
    } as HubDetail;
    expect(projectSelectFields(data).map((item) => item.id)).toEqual([
      "status",
    ]);
    expect(
      projectFieldValue(row({ values: { points: "0" } }), {
        id: "points",
        name: "Points",
        options: [],
      }),
    ).toBe("0");
    expect(
      projectDateRows(
        [
          row({ id: "late", values: { date: "2030-02-20" } }),
          row({ id: "early", values: { date: "2030-02-10" } }),
          row({ id: "invalid", values: { date: "tomorrow" } }),
          row(),
        ],
        date,
      ).map((item) => item.row.id),
    ).toEqual(["early", "late"]);
  });
  it("suggests a safe branch name without running Git", () => {
    expect(projectBranchName(row({ title: "Fix Search / keyboard!" }))).toBe(
      "feature/42-fix-search-keyboard",
    );
    expect(
      projectBranchName(row({ number: undefined, title: "문제 해결" })),
    ).toBe("feature/project-task");
    expect(
      projectBranchName(row({ title: "x".repeat(200) })).length,
    ).toBeLessThan(80);
  });
  it("builds real timeline ranges and flags reversed or invalid dates", () => {
    const start = {
        id: "start",
        name: "Start",
        kind: "date" as const,
        options: [],
      },
      end = { id: "end", name: "End", kind: "date" as const, options: [] };
    const range = projectDateRange(
      row({ values: { start: "2030-02-10", end: "2030-02-20" } }),
      start,
      end,
    )!;
    expect(range.end - range.start).toBe(10 * 86_400_000);
    expect(range.reversed).toBe(false);
    expect(
      projectDateRange(
        row({ values: { start: "2030-02-20", end: "2030-02-10" } }),
        start,
        end,
      )?.reversed,
    ).toBe(true);
    expect(
      projectDateRange(row({ values: { end: "2030-02-20" } }), start, end)
        ?.startText,
    ).toBe("2030-02-20");
    expect(
      projectDateRange(row({ values: { start: "2030-02-31" } }), start, end),
    ).toBeNull();
    expect(projectDateRange(row(), start, end)).toBeNull();
  });
  it("stops a partial batch, redacts the credential, and requires refresh before retry", async () => {
    const access = {
      target: {
        provider: "github" as const,
        host: "github.com",
        path: "team/client",
        remote: "origin",
      },
      token: "fixture-only-token",
      apiBase: "https://api.github.com",
      me: "reviewer",
    };
    const work = vi.fn(async (_access: unknown, item: HubProjectRow) => {
      if (item.id === "second") throw new Error("failed fixture-only-token");
    });
    await expect(
      runProjectBatch(
        access,
        [row({ id: "first" }), row({ id: "second" }), row({ id: "third" })],
        work,
      ),
    ).rejects.toThrow("Refresh the project");
    expect(work).toHaveBeenCalledTimes(2);
    await expect(
      runProjectBatch(access, [row({ id: "second" })], work),
    ).rejects.not.toThrow("fixture-only-token");
  });
  it("keeps refreshed project position order regardless of item update dates", () => {
    const first = row({ id: "first", updatedAt: "2030-02-20T12:00:00Z" }),
      second = row({ id: "second", updatedAt: "2030-02-10T12:00:00Z" });
    expect(
      filterProjectRows([second, first], filters).map((value) => value.id),
    ).toEqual(["second", "first"]);
  });
});
