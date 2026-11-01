import { describe, expect, it, vi } from "vitest";
const fake = vi.hoisted(() => ({ json: vi.fn() }));
vi.mock("../src/entities/flow/model/engine", () => ({ flowEngine: fake }));
vi.mock("@/shared/i18n", () => ({ t: (key: string) => key }));
import { browseFlowConnection, connectionProblem, saveFlowConnection, type FlowConnection } from "../src/entities/flow/model/connections";

const connection = (extra: Partial<FlowConnection> = {}): FlowConnection => ({ name: "build-server", kind: "jenkins", url: "https://ci.example.com", user: null, project: null, secret: "env:CI_TOKEN", allow: ["team/*"], ...extra });
describe("flow connection references", () => {
  it("accepts existing credential references without exposing token fields", () => {
    for (const secret of ["env:CI_TOKEN", "app:saved-account", "gh:account", "keystore"]) expect(connectionProblem(connection({ secret }))).toBeNull();
    expect(connectionProblem(connection({ kind: "github", url: "" }))).toBeNull();
  });
  it("rejects credentials embedded in addresses or entered as raw references", async () => {
    for (const url of ["https://user:password@ci.example.com", "https://ci.example.com?token=value", "file:///tmp/ci", "javascript:alert(1)"]) expect(connectionProblem(connection({ url }))).toBeTruthy();
    expect(connectionProblem(connection({ secret: "an-opaque-token-value" }))).toBeTruthy();
    await expect(saveFlowConnection("/tmp/repo", connection({ name: "--unsafe" }))).rejects.toThrow();
  });
  it("passes job paths as individual arguments and keeps browsing read-only", async () => {
    fake.json.mockResolvedValue({ jobs: [], runs: [], log: null });
    await browseFlowConnection("/tmp/repo", "build-server", "team/app", "42");
    expect(fake.json).toHaveBeenLastCalledWith(["ci", "browse", "team/app", "42", "--connection", "build-server"], "/tmp/repo", [0], 25_000);
  });
});
