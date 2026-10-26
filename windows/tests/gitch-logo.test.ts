import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { gitch } from "@/entities/gitch";
import { ipc } from "@/shared/api";

const preference = (enabled: boolean) => JSON.stringify({ schemaVersion: 1, enabled });

beforeEach(() => {
  vi.spyOn(gitch, "bundled", "get").mockReturnValue("/bundled/gitch");
  vi.spyOn(gitch, "bash").mockResolvedValue("/bin/bash");
  vi.spyOn(ipc, "exists").mockResolvedValue(true);
});
afterEach(() => vi.restoreAllMocks());

describe("CLI 로고 설정", () => {
  it("계정이나 셸 명령 설치 없이 내장 CLI의 설정을 읽는다", async () => {
    const config = vi.spyOn(gitch, "hasConfig").mockResolvedValue(false);
    const installed = vi.spyOn(gitch, "installed").mockResolvedValue(null);
    const run = vi.spyOn(ipc, "run").mockResolvedValue({ status: 0, stdout: preference(false), stderr: "" });
    expect(await gitch.logo()).toBe(false);
    expect(config).not.toHaveBeenCalled();
    expect(installed).not.toHaveBeenCalled();
    expect(run.mock.calls[0][1]).toEqual(["/bundled/gitch", "logo", "--json"]);
    expect(run.mock.calls[0][2]?.env).toMatchObject({ GITSW_COLOR: "never", GITSW_BANNER: "never" });
  });

  it.each([true, false])("저장한 실제 상태를 반환한다: %s", async (enabled) => {
    const run = vi.spyOn(ipc, "run").mockResolvedValue({ status: 0, stdout: preference(enabled), stderr: "" });
    expect(await gitch.setLogo(enabled)).toBe(enabled);
    expect(run.mock.calls[0][1]).toEqual(["/bundled/gitch", "logo", enabled ? "on" : "off", "--json"]);
  });

  it.each(["broken", "null", "{}", '{"schemaVersion":2,"enabled":false}', '{"schemaVersion":1,"enabled":"false"}'])("잘못된 응답을 꺼진 상태로 처리하지 않는다: %s", async (stdout) => {
    vi.spyOn(ipc, "run").mockResolvedValue({ status: 0, stdout, stderr: "" });
    await expect(gitch.logo()).rejects.toThrow("Couldn't read the CLI logo setting.");
  });

  it("저장 실패의 이유를 보이고 성공한 것으로 반환하지 않는다", async () => {
    vi.spyOn(ipc, "run").mockResolvedValue({ status: 1, stdout: preference(false), stderr: '{"error":{"message":"Settings directory is read-only"}}' });
    await expect(gitch.setLogo(false)).rejects.toThrow("Settings directory is read-only");
  });

  it("내장 CLI가 없으면 설치된 다른 사본으로 설정을 바꾸지 않는다", async () => {
    vi.spyOn(ipc, "exists").mockResolvedValue(false);
    const run = vi.spyOn(ipc, "run");
    await expect(gitch.setLogo(false)).rejects.toThrow("Couldn't find gitch inside Gitrochi.");
    expect(run).not.toHaveBeenCalled();
  });
});
