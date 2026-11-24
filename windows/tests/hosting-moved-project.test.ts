import { afterEach, describe, expect, it, vi } from "vitest";
import { movedProject, sendRaw } from "@/entities/hosting";
import { ipc } from "@/shared/api";

afterEach(() => vi.restoreAllMocks());

describe("moved GitLab projects", () => {
  it("rewrites only addresses that name the project by path", () => {
    const moved = movedProject("https://gitlab.example.com/api/v4/projects/team%2Frepo/jobs/9/play?x=1");
    expect(moved?.lookup).toBe("https://gitlab.example.com/api/v4/projects/team%2Frepo");
    expect(moved?.url(42)).toBe("https://gitlab.example.com/api/v4/projects/42/jobs/9/play?x=1");
    expect(movedProject("https://gitlab.example.com/api/v4/projects/team%2Frepo")?.url(42)).toBe("https://gitlab.example.com/api/v4/projects/42");
    expect(movedProject("https://gitlab.example.com/api/v4/projects/42/jobs/9/play")).toBeNull();
    expect(movedProject("https://gitlab.example.com/api/v4/user")).toBeNull();
  });

  it("retries a refused write by the project's id", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (method, url) => {
      if (url.endsWith("/projects/old%2Frepo/jobs/9/play")) return { status: 405, body: '{"message":"Non GET methods are not allowed for moved projects"}' };
      if (method === "GET" && url.endsWith("/projects/old%2Frepo")) return { status: 200, body: '{"id":42}' };
      if (method === "POST" && url.endsWith("/projects/42/jobs/9/play")) return { status: 200, body: "{}" };
      return { status: 500, body: "" };
    });
    await expect(sendRaw("gitlab", "https://gitlab.example.com/api/v4/projects/old%2Frepo/jobs/9/play", "fixture", "POST")).resolves.toBe("{}");
    expect(http).toHaveBeenCalledTimes(3);
  });
});
