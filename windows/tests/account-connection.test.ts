import { afterEach, describe, expect, it, vi } from "vitest";
import { AccountConnectionFailure, accountConnectionMessage, AccountStore } from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { settings } from "@/shared/config";

const privateOutput = "fixture-private-credential-output";
const store = () => {
  const account = new AccountStore();
  vi.spyOn(account, "ghPath", "get").mockReturnValue("/fixture/gh");
  return account;
};

afterEach(() => vi.restoreAllMocks());

describe("저장된 토큰 읽기", () => {
  it("읽지 못한 토큰은 다음 접근에서 다시 읽고, 읽은 값은 기억하며, 동시 접근은 한 번만 읽는다", async () => {
    const get = vi.spyOn(ipc, "secretGet").mockResolvedValueOnce(null).mockRejectedValueOnce(new Error("locked")).mockResolvedValue("fixture-token");
    const account = new AccountStore();
    const a = { id: "one", provider: "github" as const, server: "https://github.com", username: "octocat", name: null, avatarURL: null };
    expect(await account.token(a)).toBeNull();
    expect(await account.token(a)).toBeNull();
    expect(await Promise.all([account.token(a), account.token(a)])).toEqual(["fixture-token", "fixture-token"]);
    expect(await account.token(a)).toBe("fixture-token");
    expect(get).toHaveBeenCalledTimes(3);
  });

  it("연결 해제 뒤에 늦게 끝난 읽기는 토큰을 되살리지 않는다", async () => {
    let finish: (value: string | null) => void = () => {};
    vi.spyOn(ipc, "secretGet").mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; })).mockResolvedValue(null);
    vi.spyOn(ipc, "secretSet").mockResolvedValue(undefined);
    const account = new AccountStore();
    const a = { id: "one", provider: "github" as const, server: "https://github.com", username: "octocat", name: null, avatarURL: null };
    const late = account.token(a);
    await account.disconnect(a);
    finish("stale-token");
    expect(await late).toBe("stale-token");
    expect(await account.token(a)).toBeNull();
  });
});

describe("승인 후 계정 연결 실패", () => {
  it("CLI 실행 실패와 자격 증명 읽기 실패에서 원래 출력을 노출하지 않는다", async () => {
    const run = vi.spyOn(ipc, "run").mockRejectedValue(new Error(privateOutput));
    const account = store();
    await expect(account.importGitHubCLI("octocat")).rejects.toMatchObject({ stage: "credential-read" });
    run.mockResolvedValue({ status: 1, stdout: privateOutput, stderr: privateOutput });
    try { await account.importGitHubCLI("octocat"); throw new Error("Expected import failure"); }
    catch (error) {
      expect(error).toBeInstanceOf(AccountConnectionFailure);
      expect(accountConnectionMessage(error)).toContain("GitHub CLI");
      expect(accountConnectionMessage(error)).not.toContain(privateOutput);
    }
    expect(account.accounts).toEqual([]);
  });

  it("API 확인 실패는 응답 본문 대신 HTTP 상태와 복구 안내만 보인다", async () => {
    vi.spyOn(ipc, "run").mockResolvedValue({ status: 0, stdout: privateOutput, stderr: "" });
    vi.spyOn(ipc, "http").mockResolvedValue({ status: 403, body: JSON.stringify({ message: privateOutput }) });
    const save = vi.spyOn(ipc, "secretSet").mockResolvedValue(undefined);
    const account = store();
    try { await account.importGitHubCLI("octocat"); throw new Error("Expected verification failure"); }
    catch (error) {
      expect(error).toMatchObject({ stage: "verification" });
      expect(accountConnectionMessage(error)).toContain("403");
      expect(accountConnectionMessage(error)).not.toContain(privateOutput);
    }
    expect(save).not.toHaveBeenCalled();
    expect(account.revision).toBe(0);
  });

  it("비밀 저장소 실패 뒤에는 계정을 연결 완료로 기록하지 않는다", async () => {
    vi.spyOn(ipc, "run").mockResolvedValue({ status: 0, stdout: privateOutput, stderr: "" });
    vi.spyOn(ipc, "http").mockResolvedValue({ status: 200, body: '{"login":"octocat","name":null,"avatar_url":null}' });
    vi.spyOn(ipc, "secretSet").mockRejectedValue(new Error(privateOutput));
    const account = store();
    try { await account.importGitHubCLI("octocat"); throw new Error("Expected credential-save failure"); }
    catch (error) {
      expect(error).toMatchObject({ stage: "credential-save" });
      expect(accountConnectionMessage(error)).toContain("Credential Manager");
      expect(accountConnectionMessage(error)).not.toContain(privateOutput);
    }
    expect(account.accounts).toEqual([]);
    expect(account.revision).toBe(0);
  });

  it("승인한 사용자와 다른 계정은 저장하지 않고 성공한 계정만 공개 상태에 추가한다", async () => {
    const run = vi.spyOn(ipc, "run").mockResolvedValue({ status: 0, stdout: privateOutput, stderr: "" });
    const http = vi.spyOn(ipc, "http").mockResolvedValue({ status: 200, body: '{"login":"other-user","name":null,"avatar_url":null}' });
    const save = vi.spyOn(ipc, "secretSet").mockResolvedValue(undefined);
    vi.spyOn(settings, "set").mockImplementation(() => {});
    const account = store();
    await expect(account.importGitHubCLI("octocat")).rejects.toMatchObject({ stage: "identity-mismatch" });
    expect(save).not.toHaveBeenCalled();
    http.mockResolvedValue({ status: 200, body: '{"login":"octocat","name":null,"avatar_url":null}' });
    expect((await account.importGitHubCLI("octocat")).username).toBe("octocat");
    expect(run.mock.calls[0][1]).toEqual(["auth", "token", "--hostname", "github.com", "--user", "octocat"]);
    expect(account.accounts).toHaveLength(1);
    expect(account.revision).toBe(1);
  });

  it("알 수 없는 오류의 토큰과 비밀 저장소 상세를 연결 화면에 보내지 않는다", () => {
    expect(accountConnectionMessage(new Error(privateOutput))).not.toContain(privateOutput);
    expect(accountConnectionMessage(new AccountConnectionFailure("identity-mismatch", { expectedLogin: "octocat" }))).toContain("octocat");
    expect(accountConnectionMessage(new AccountConnectionFailure("verification", { status: 401 }))).toContain("401");
  });

  it("프로젝트 추가 승인 뒤 기존 계정의 자격 증명을 갱신하고 중복 계정을 만들지 않는다", async () => {
    vi.spyOn(ipc, "run").mockResolvedValue({ status: 0, stdout: privateOutput, stderr: "" });
    vi.spyOn(ipc, "http").mockResolvedValue({ status: 200, body: '{"login":"octocat","name":null,"avatar_url":null}' });
    const save = vi.spyOn(ipc, "secretSet").mockResolvedValue(undefined);
    vi.spyOn(settings, "set").mockImplementation(() => {});
    const account = store();
    account.accounts = [{ id: "existing-account", provider: "github", server: "https://github.com", username: "octocat", name: null, avatarURL: null }];
    const connected = await account.importGitHubCLI("octocat");
    expect(connected.id).toBe("existing-account");
    expect(account.accounts).toHaveLength(1);
    expect(save).toHaveBeenCalledWith("acct:existing-account", privateOutput);
    expect(await account.token(connected)).toBe(privateOutput);
  });
});
