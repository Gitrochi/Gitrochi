import { afterEach, describe, expect, it, vi } from "vitest";
import { decodeAgentAssignments, decodeValidationBindings, flowEvidence, handoffReport, safeWorkPath, taskBoundaryOverlaps, type ValidationBinding } from "../src/shared/lib/work-validation";
import { decodeTeamSnapshot, readTeamSnapshot, teamHubEndpoint, teamRepoKey } from "../src/shared/lib/team-hub";
import { ipc } from "../src/shared/api";

const head = "a".repeat(40);
const binding: ValidationBinding = { schemaVersion: 1, runID: "run-1", head, before: "content", after: "content", candidates: ["tests/a.ts"], observedAt: "2026-01-01T00:00:00Z" };
const record = { runId: "run-1", state: "SUCCEEDED", finishedAt: "2026-01-01T00:00:10Z", git: { sha: head }, nodes: [{ tests: { executed: 4, passed: 3, failed: 1 } }, { state: "PASSED" }] };
afterEach(() => vi.restoreAllMocks());

describe("bound verification evidence", () => {
  it("requires matching run, revision and before/after/current contents", () => {
    expect(flowEvidence(record, binding, "content")).toMatchObject({ freshness: "current", executed: 4, passed: 3, failed: 1 });
    expect(flowEvidence(record, { ...binding, before: "older" }, "content").freshness).toBe("stale");
    expect(flowEvidence(record, { ...binding, head: "b".repeat(40) }, "content").freshness).toBe("stale");
    expect(flowEvidence(record, binding, "changed").freshness).toBe("stale");
    expect(flowEvidence(record, { ...binding, runID: "other" }, "content").freshness).toBe("unbound");
    expect(flowEvidence(record, { ...binding, after: undefined }, "content").freshness).toBe("unbound");
    expect(flowEvidence({ ...record, state: "UNKNOWN" }, binding, "content").freshness).toBe("unbound");
    expect(flowEvidence({ ...record, finishedAt: undefined }, binding, "content").freshness).toBe("unbound");
  });
  it("never certifies unknown untracked contents or invents test execution", () => {
    expect(flowEvidence(record, { ...binding, before: "untracked:x", after: "untracked:x" }, "untracked:x").freshness).toBe("stale");
    expect(flowEvidence({ ...record, nodes: [{ state: "PASSED" }] }, binding, "content").executed).toBeNull();
    expect(flowEvidence({ ...record, nodes: [{ tests: { executed: 2 } }] }, binding, "content").passed).toBeNull();
    expect(flowEvidence({ ...record, nodes: [{ tests: { executed: -1, passed: 9 } }] }, binding, "content").executed).toBeNull();
    expect(flowEvidence({ ...record, state: "RUNNING" }, binding, "content").freshness).toBe("running");
    expect(flowEvidence({ ...record, nodes: [{ tests: { executed: Number.MAX_SAFE_INTEGER } }, { tests: { executed: 1 } }] }, binding, "content").executed).toBeNull();
  });
  it("rejects corrupt persisted bindings and unsafe ownership paths", () => {
    expect(decodeValidationBindings([binding, { ...binding, schemaVersion: true }, { ...binding, candidates: ["../outside"] }])).toEqual([binding]);
    expect(["../file", "/absolute", "C:/file", "a\\b", "a//b", "a\nb"].some(safeWorkPath)).toBe(false);
    expect(safeWorkPath("src/문서.ts")).toBe(true);
  });
  it("compares deliberate task boundaries without inferring authorship", () => {
    const rows = decodeAgentAssignments([{ sessionID: "a", taskID: "1", goal: "Parse", paths: ["src/core"], remaining: "Review" }, { sessionID: "b", taskID: "2", goal: "Index", paths: ["src/core/index.ts"], remaining: "Test" }]);
    expect(taskBoundaryOverlaps(rows)).toEqual([{ a: "a", b: "b", paths: ["src/core/index.ts"] }]);
    expect(decodeAgentAssignments([{ ...rows[0], paths: ["../secret"] }])).toEqual([]);
    expect(taskBoundaryOverlaps([{ ...rows[0], paths: ["src/core2"] }, rows[1]])).toEqual([]);
  });
  it("exports revision and actual evidence without candidate coverage claims", () => {
    const report = JSON.parse(handoffReport({ head, stamp: "content", candidates: ["tests/a.ts", "../no"], evidence: [flowEvidence(record, binding, "content")], assignments: [], observedAt: binding.observedAt }));
    expect(report.revision).toBe(head);
    expect(report.candidates).toEqual(["tests/a.ts"]);
    expect(report.verification[0].executed).toBe(4);
    expect(report.limitations.join(" ")).toContain("not proof");
    expect(report).not.toHaveProperty("repositoryPath");
    const quoted = JSON.parse(handoffReport({ head, stamp: "content", candidates: [], evidence: [], assignments: [{ sessionID: "session", taskID: "1", goal: 'Inspect C:/fixture/a"b', paths: [], remaining: "" }], observedAt: binding.observedAt }));
    expect(quoted.assignments[0].goal).not.toContain("C:/fixture");
  });
});

describe("read-only team hub snapshots", () => {
  const repo = "example.com/team/app", now = new Date("2026-01-01T00:00:30Z");
  const member = (name: string, expires = "2026-01-01T00:01:00Z") => ({ member: name, client: "desktop", branch: "feature/example", head, changed: ["src/a.ts"], related: [], updated: "2026-01-01T00:00:00Z", expires });
  const a = member("member-a"), b = member("member-b");
  const overlap = { kind: "same-file", a, b, paths: ["src/a.ts"] };
  it("normalizes remote identities and only allows encrypted or loopback endpoints", () => {
    expect(teamRepoKey("ssh://git@example.com:2222/team/App.git")).toBe("example.com/team/App");
    expect(teamRepoKey("git@example.com:team/app.git")).toBe(repo);
    expect(teamHubEndpoint("http://127.0.0.1:7420/")).toBe("http://127.0.0.1:7420");
    for (const url of ["http://hub.example.com", "https://name:secret@example.com", "https://example.com?token=value", "file:///fixture"]) expect(() => teamHubEndpoint(url)).toThrow();
    expect(() => teamRepoKey("file:///fixture")).toThrow();
  });
  it("handles empty Go slices, expiry, duplicated observations and mismatched repositories", () => {
    expect(decodeTeamSnapshot(repo, { repo, presence: null }, { repo, overlaps: null }, now).overlaps).toEqual([]);
    expect(decodeTeamSnapshot(repo, { repo, presence: [a, b] }, { repo, overlaps: [overlap, overlap] }, now).overlaps).toHaveLength(1);
    expect(decodeTeamSnapshot(repo, { repo, presence: [a, member("member-b", "2026-01-01T00:00:01Z")] }, { repo, overlaps: [overlap] }, now).overlaps).toHaveLength(0);
    expect(() => decodeTeamSnapshot(repo, { repo: "other/repo", presence: [] }, { repo, overlaps: [] }, now)).toThrow();
  });
  it("reads only the two bounded v1 snapshot resources", async () => {
    const request = vi.spyOn(ipc, "hubRead").mockImplementation(async url => ({ status: 200, body: JSON.stringify(url.endsWith("/presence") ? { repo, presence: [] } : { repo, overlaps: [] }) }));
    const result = await readTeamSnapshot("https://hub.example.com", repo, "fixture-token");
    expect(result.repo).toBe(repo);
    expect(request.mock.calls.map(call => call[0])).toEqual(["https://hub.example.com/api/v1/repos/example.com/team/app/presence", "https://hub.example.com/api/v1/repos/example.com/team/app/overlaps"]);
    request.mockResolvedValue({ status: 401, body: "unauthorized" });
    await expect(readTeamSnapshot("https://hub.example.com", repo, "fixture-token")).rejects.toThrow("401");
  });
});
