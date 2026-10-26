import { describe, expect, it, vi } from "vitest";
import { accountAddArguments, browserLoginArguments, browserLoginTimeout, gitch, machineError, parseAccountSetup, parseBrowserLogin, parseDoctor } from "@/entities/gitch";
import { AccountStore } from "@/entities/hosting";
import { ipc } from "@/shared/api";

const result = (overrides = {}) => JSON.stringify({ schemaVersion: 1, created: true,
  account: { id: "alice", email: "alice@example.com", host: "github.com", port: 22, folder: null, via: null },
  ssh: { alias: "github-alice", keyExists: false, publicKey: "", registrationURL: "https://github.com/settings/ssh/new", authenticated: null, keyProtection: "missing", message: "Register a public key" }, ...overrides });

describe("앱의 Git 계정 설정", () => {
  it("프로젝트 권한은 선택한 계정의 추가 승인에만 요청한다", () => {
    expect(browserLoginArguments()).toEqual(["--start", "--yes"]);
    expect(browserLoginArguments("standard", "alice")).toEqual(["--start", "--yes", "--expected-login", "alice"]);
    expect(browserLoginArguments("projects", "Alice")).toEqual(["--start", "--yes", "--capability", "projects", "--expected-login", "Alice"]);
    expect(() => browserLoginArguments("projects")).toThrow("Select the GitHub account");
    expect(() => browserLoginArguments("projects", "$(touch PWNED)")).toThrow("valid GitHub account");
    expect(() => browserLoginArguments("projects", "")).toThrow("valid GitHub account");
  });
  it("계정 추가 인자를 셸 코드로 합치지 않고 별도 인자로 전달한다", () => {
    const folder = "C:/Work/한글 $literal/it's a folder";
    expect(accountAddArguments({ id: " alice ", email: "alice@example.com", host: "github.com", port: 2222, folder, via: null })).toEqual(["add", "--id", "alice", "--email", "alice@example.com", "--host", "github.com", "--port", "2222", "--folder", folder, "--no-setup", "--json", "--yes"]);
    expect(accountAddArguments({ id: "bob", email: "bob@example.com", host: "git.example.com", port: 22, folder: null, via: "alice" })).toContain("--no-folder");
  });
  it("키 생성 전과 인증 실패도 정상 설정 상태로 읽는다", () => {
    expect(parseAccountSetup(result())?.ssh.keyExists).toBe(false);
    const o = JSON.parse(result()); o.ssh.authenticated = false;
    expect(parseAccountSetup(JSON.stringify(o))?.ssh.authenticated).toBe(false);
    o.ssh.publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample alice@example.com";
    expect(parseAccountSetup(JSON.stringify(o))?.ssh.publicKey).toContain("ssh-ed25519");
  });
  it("다른 서버·실행 가능한 URL과 잘못된 키 응답은 열거나 복사하지 않는다", () => {
    for (const url of ["javascript:alert(1)", "http://github.com/settings", "https://evil.example/settings", "https://user:password@github.com/settings", "https://github.com:444/settings"]) {
      const o = JSON.parse(result()); o.ssh.registrationURL = url;
      expect(parseAccountSetup(JSON.stringify(o))).toBeNull();
    }
    const o = JSON.parse(result()); o.ssh.publicKey = "invalid-not-a-public-ssh-key";
    expect(parseAccountSetup(JSON.stringify(o))).toBeNull();
    expect(parseAccountSetup("broken")).toBeNull();
  });
  it("doctor의 경고와 CLI 오류의 실제 이유를 보인다", () => {
    expect(parseDoctor('{"schemaVersion":1,"problems":1,"items":[{"section":"SSH","level":"WARN","message":"Register key"}]}')?.checks[0].message).toBe("Register key");
    expect(machineError('{"schemaVersion":1,"error":{"message":"Account already exists"}}')).toBe("Account already exists");
  });
  it("로그인 코드는 GitHub의 고정 장치 인증 페이지로만 전달한다", () => {
    const flow = { schemaVersion: 1, session: "session-123", state: "pending", deviceCode: "ABCD-1234", verificationURL: "https://github.com/login/device", login: null, email: null, message: "Waiting" };
    expect(parseBrowserLogin(JSON.stringify(flow))?.deviceCode).toBe("ABCD-1234");
    expect(parseBrowserLogin(JSON.stringify({ ...flow, phase: "approval" }))?.phase).toBe("approval");
    for (const patch of [{ session: "../other" }, { verificationURL: "https://evil.example" }, { deviceCode: "<script>" }, { state: "complete" }, { phase: "unexpected" }]) expect(parseBrowserLogin(JSON.stringify({ ...flow, ...patch }))).toBeNull();
  });
  it("코드 준비와 승인 만료를 구분하고 다른 로그인 대기를 코드 실패로 처리하지 않는다", () => {
    const flow = parseBrowserLogin(JSON.stringify({ schemaVersion: 1, session: "session-123", state: "pending", deviceCode: null, verificationURL: "https://github.com/login/device", login: null, email: null, message: "Waiting" }))!;
    expect(browserLoginTimeout(flow, 59_999)).toBeNull();
    expect(browserLoginTimeout(flow, 60_000)).toBe("code");
    expect(browserLoginTimeout({ ...flow, phase: "queued" }, 899_999)).toBeNull();
    expect(browserLoginTimeout({ ...flow, phase: "preparing" }, 150_000, 59_000)).toBeNull();
    expect(browserLoginTimeout({ ...flow, phase: "preparing" }, 150_000, 60_000)).toBe("code");
    expect(browserLoginTimeout({ ...flow, deviceCode: "ABCD-1234" }, 899_999)).toBeNull();
    expect(browserLoginTimeout({ ...flow, deviceCode: "ABCD-1234" }, 900_000)).toBe("approval");
    expect(browserLoginTimeout({ ...flow, state: "cancelled" }, 900_000)).toBeNull();
  });
  it("계정이 없는 첫 실행도 내장 CLI를 사용하며 SSH 인증 실패 결과를 유지한다", async () => {
    const o = JSON.parse(result()); o.ssh.authenticated = false;
    const exists = vi.spyOn(ipc, "exists").mockResolvedValue(true);
    const spawn = vi.spyOn(ipc, "run").mockResolvedValue({ status: 1, stdout: JSON.stringify(o), stderr: "" });
    const bundled = vi.spyOn(gitch, "bundled", "get").mockReturnValue("/bundled/gitch");
    const bash = vi.spyOn(gitch, "bash").mockResolvedValue("/bin/bash");
    try {
      expect((await gitch.checkAccountConnection("alice")).ssh.authenticated).toBe(false);
      expect(spawn.mock.calls[0][1]).toEqual(["/bundled/gitch", "setup", "alice", "--check", "--json"]);
    } finally { exists.mockRestore(); spawn.mockRestore(); bundled.mockRestore(); bash.mockRestore(); }
  });
});

describe("GitHub 공개키 자동 등록", () => {
  const key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample alice@example.com";
  const store = () => {
    const a = new AccountStore();
    a.accounts = [{ id: "test-only", provider: "github", server: "https://github.com", username: "alice", name: null, avatarURL: null }];
    vi.spyOn(a, "token").mockResolvedValue("fixture-token");
    return a;
  };
  it("서버에서 현재 사용자를 확인한 뒤 공개키만 등록한다", async () => {
    const http = vi.spyOn(ipc, "http").mockImplementation(async (method, url) => ({ status: 200, body: JSON.stringify(url.endsWith("/user") ? { login: "alice" } : method === "GET" ? [] : { id: 1 }) }));
    try {
      await store().registerGitHubSSHKey("alice", key);
      const post = http.mock.calls.find((c) => c[0] === "POST")!;
      expect(post[1]).toBe("https://api.github.com/user/keys");
      expect(JSON.parse(post[3]!)).toEqual({ title: "Gitrochi (alice)", key });
    } finally { http.mockRestore(); }
  });
  it("다른 사용자나 기존 공개키에는 POST를 보내지 않는다", async () => {
    const http = vi.spyOn(ipc, "http").mockResolvedValue({ status: 200, body: '{"login":"bob"}' });
    try {
      await expect(store().registerGitHubSSHKey("alice", key)).rejects.toThrow("different account");
      expect(http.mock.calls.some((c) => c[0] === "POST")).toBe(false);
      http.mockClear();
      http.mockImplementation(async (_method, url) => ({ status: 200, body: JSON.stringify(url.endsWith("/user") ? { login: "alice" } : [{ key: key.replace("alice@example.com", "old-comment") }]) }));
      await store().registerGitHubSSHKey("alice", key);
      expect(http.mock.calls.some((c) => c[0] === "POST")).toBe(false);
    } finally { http.mockRestore(); }
  });
});
