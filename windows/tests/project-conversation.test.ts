import { describe, expect, it } from "vitest";
import type { HubAccess, HubProjectRow } from "@/entities/hosting";
import { projectConversationContext } from "../src/widgets/hosting-hub/lib/project-conversation";
const access: HubAccess = { target: { provider: "github", host: "github.com", path: "owner/workspace", remote: "origin" }, token: "fixture-only", apiBase: "https://api.github.com", me: "planner", stillCurrent: () => true };
const row: HubProjectRow = { id: "ITEM", contentID: "ISSUE", kind: "issue", number: 8, title: "Plan release", body: "Notes", repository: "team/client", url: "https://github.com/team/client/issues/8", statuses: {} };
describe("project conversation destination", () => {
  it("uses the selected row repository while preserving the authenticated context", () => {
    const result = projectConversationContext(access, row);
    expect(result.access.target.path).toBe("team/client");
    expect(result.access.token).toBe(access.token);
    expect(result.access.stillCurrent).toBe(access.stillCurrent);
    expect(result.item.number).toBe(8);
    expect(result.item.isRequest).toBe(false);
  });
  it("rejects local drafts, another server, and conflicting row metadata", () => {
    expect(() => projectConversationContext({ ...access, local: true }, row)).toThrow();
    expect(() => projectConversationContext(access, { ...row, kind: "draft" })).toThrow();
    expect(() => projectConversationContext(access, { ...row, url: "https://example.com/team/client/issues/8" })).toThrow();
    expect(() => projectConversationContext(access, { ...row, repository: "another/repo" })).toThrow();
    expect(() => projectConversationContext(access, { ...row, number: 9 })).toThrow();
  });
  it("identifies pull requests and nested GitLab issue repositories", () => {
    expect(projectConversationContext(access, { ...row, kind: "pullRequest", url: "https://github.com/team/client/pull/8" }).item.isRequest).toBe(true);
    const result = projectConversationContext({ ...access, apiBase: "https://gitlab.example.com/api/v4", target: { ...access.target, provider: "gitlab", host: "gitlab.example.com" } }, { ...row, repository: "group/team/client", url: "https://gitlab.example.com/group/team/client/-/issues/8" });
    expect(result.access.target.path).toBe("group/team/client");
  });
});
