import { describe, expect, it } from "vitest";
import { commitStop, countGraphRules, fromPosix, graphDiffRelations, linkTarget, parseAccounts, parseBackups, parseGraphCheck, parseGraphSummary, parseGraphWatchURL, parsePreflight, parseStatus, plain, supportsGraph, versionAtLeast, versionOf, type GitchLevel, type GitchPreflight, type GitchStatus } from "@/entities/gitch";

describe("구조 그래프(gitch graph)", () => {
  it("감시 서버 주소는 반환한 로컬 HTTP 주소만 연다", () => {
    expect(parseGraphWatchURL('{"url":"http://127.0.0.1:8765/token/"}')).toBe("http://127.0.0.1:8765/token/");
    for (const url of ["https://example.com/", "file:///tmp/a.html", "http://127.0.0.1/", "http://user:pass@127.0.0.1:8765/"]) expect(parseGraphWatchURL(JSON.stringify({ url }))).toBeNull();
    expect(parseGraphWatchURL("broken")).toBeNull();
  });
  it("버전은 숫자로 비교(3.10 > 3.2)", () => {
    expect(versionAtLeast("3.2.0", "3.2.0")).toBe(true);
    expect(versionAtLeast("3.10.0", "3.2.0")).toBe(true);
    expect(versionAtLeast("3.1.9", "3.2.0")).toBe(false);
    expect(versionAtLeast("4", "3.2.0")).toBe(true);
  });

  it("앱과 버전을 맞춘 CLI 는 그래프 API 표시로, 옛 CLI 는 기존 버전으로 확인한다", () => {
    const shared = 'GITCH_VERSION="0.3.10"\nGITCH_VERSION_SCHEME="gitrochi"\nGITCH_GRAPH_API="1"\n';
    expect(supportsGraph(shared)).toBe(true);
    expect(supportsGraph(shared.replace('API="1"', 'API="2"'))).toBe(true);
    expect(supportsGraph(shared.replaceAll("\n", "\r\n"))).toBe(true);
    expect(supportsGraph('GITCH_VERSION="3.2.0"\n')).toBe(true);
    expect(supportsGraph('GITCH_VERSION="3.10.0"\n')).toBe(true);
    expect(supportsGraph('GITCH_VERSION="3.1.9"\n')).toBe(false);
    expect(supportsGraph('GITCH_VERSION="0.3.10"\n')).toBe(false);
    expect(supportsGraph('GITCH_VERSION="broken"\n')).toBe(false);
    expect(supportsGraph("")).toBe(false);
  });

  it("기능 표시가 잘못됐거나 일부만 있으면 옛 버전 검사로 우회하지 않는다", () => {
    const header = 'GITCH_VERSION="3.2.1"\nGITCH_VERSION_SCHEME="gitrochi"\nGITCH_GRAPH_API="1"\n';
    for (const value of ["0", "-1", "1.0", "garbage", ""]) {
      expect(supportsGraph(header.replace('API="1"', `API="${value}"`))).toBe(false);
    }
    expect(supportsGraph(header.replace('GITCH_GRAPH_API="1"\n', ""))).toBe(false);
    expect(supportsGraph(header.replace('GITCH_VERSION_SCHEME="gitrochi"\n', ""))).toBe(false);
    expect(supportsGraph(header.replace('SCHEME="gitrochi"', 'SCHEME="unknown"'))).toBe(false);
    expect(supportsGraph(header.replace('API="1"', "API=1"))).toBe(false);
    expect(supportsGraph(header.replace('GITCH_GRAPH_API=', 'export GITCH_GRAPH_API='))).toBe(false);
    expect(supportsGraph(header + 'GITCH_GRAPH_API="1"\n')).toBe(false);
    expect(supportsGraph(header + 'GITCH_VERSION_SCHEME="gitrochi"\n')).toBe(false);
  });

  it("끝 줄의 노드 수(경로에 빈칸 · NODES= 가 있어도 뒤에서), 그릴 것이 없을 때 안내", () => {
    expect(parseGraphSummary("  ~/AppData/Local/Temp/gitch-graph/a.html\nGRAPH_FILE=/c/x y/NODES=3 dir/a.html NODES=12 EDGES=30\n")).toEqual({ nodes: 12, hint: null });
    expect(parseGraphSummary("⚠ 모듈 설정 파일을 찾지 못했습니다 (Package.swift · package.json …)\nGRAPH_FILE=/tmp/m.html NODES=0 EDGES=0")).toEqual({
      nodes: 0,
      hint: "모듈 설정 파일을 찾지 못했습니다 (Package.swift · package.json …)",
    });
    expect(parseGraphSummary("")).toEqual({ nodes: null, hint: null });
  });
});

describe("바뀐 의존 · 의존 규칙 검사(gitch graph diff · check)", () => {
  it("diff 는 같이 바뀌는 파일을 비교하지 않는다", () => {
    expect(graphDiffRelations().map((r) => r.id)).toEqual(["files", "modules", "tree"]);
  });

  it("check JSON: 위반 · 경고, 순환은 노드 목록으로", () => {
    const out = [
      '{"tool":"gitch graph check","file":".gitch/graph.rules","base":null,"ok":false,"violations":[',
      '  {"relation":"files","severity":"error","line":3,"rule":"forbid  src/ui -> src/db","kind":"forbid","source":"src/ui/view.ts","target":"src/db/table.ts","existing":false},',
      '  {"relation":"files","severity":"warning","line":2,"rule":"no-cycles src/**","kind":"no-cycles","nodes":["src/a.swift","src/b.swift"],"existing":false}',
      "]}",
    ].join("\n");
    expect(parseGraphCheck(out)).toEqual({
      file: ".gitch/graph.rules",
      ok: false,
      violations: [
        { relation: "files", severity: "error", line: 3, rule: "forbid  src/ui -> src/db", kind: "forbid", source: "src/ui/view.ts", target: "src/db/table.ts", nodes: null },
        { relation: "files", severity: "warning", line: 2, rule: "no-cycles src/**", kind: "no-cycles", source: null, target: null, nodes: ["src/a.swift", "src/b.swift"] },
      ],
    });
    expect(parseGraphCheck('{"tool":"gitch graph check","file":".gitch/graph.rules","base":null,"ok":true,"violations":[]}')).toEqual({ file: ".gitch/graph.rules", ok: true, violations: [] });
    // 규칙 파일이 틀리면 gitch 는 JSON 없이 표준오류에만 쓴다
    expect(parseGraphCheck("")).toBeNull();
    expect(parseGraphCheck("{}")).toBeNull();
  });

  it("규칙 줄 수: 주석 · 빈 줄 · [절] 머리는 세지 않는다(--init 예시는 0)", () => {
    expect(countGraphRules("# gitch graph check 규칙\n\n[modules]\n# no-cycles\n\n[files]\n# forbid  src/ui -> src/db   # 예\n")).toBe(0);
    expect(countGraphRules("[files]\r\nno-cycles src/**\r\nforbid  src/ui -> src/db   # 화면은 DB 를 모른다\r\n\r\n[modules]\nlayers  *App > *Feature\n")).toBe(3);
  });
});

describe("gitch 출력 읽기", () => {
  it("status: 빈 글자는 null 로(잠기지 않은 저장소를 잠긴 것으로 보지 않게)", () => {
    const s = parseStatus('{"inRepo":true,"lockedAccount":"","account":"alice","accountSource":"folder","pushAccount":"alice","ignored":false,"warnings":[]}');
    expect(s).toEqual({ inRepo: true, lockedAccount: null, account: "alice", accountSource: "folder", pushAccount: "alice", ignored: false });
    expect(parseStatus('{"inRepo":false,"folderAccount":null}')?.inRepo).toBe(false);
    expect(parseStatus("not json")).toBeNull();
  });

  it("preflight: STOP 이어도 JSON 을 그대로", () => {
    const p = parsePreflight('{"result":"STOP","checks":[{"level":"STOP","code":"identity","message":"작성자가 다릅니다"}]}');
    expect(p?.result).toBe("STOP");
    expect(p?.checks[0].message).toBe("작성자가 다릅니다");
    expect(parsePreflight("{}")).toBeNull();
  });

  it("list: 계정과 규칙 문구", () => {
    const a = parseAccounts('{"accounts":[{"id":"bob","email":"bob@example.com","hosts":"github.com","rules":"~/Develop/bob, 조직 github.com/teamb","sshKey":false,"current":false}]}');
    expect(a).toEqual([{ id: "bob", email: "bob@example.com", hosts: "github.com", rules: "~/Develop/bob, 조직 github.com/teamb", sshKey: false }]);
    expect(parseAccounts("")).toEqual([]);
  });

  it("백업: 최근 것이 먼저, 수정 중이던 파일(-wip)은 따로 보이지 않고 표시만", () => {
    const out = [
      "refs/gitch/backup/20261023-163654-pl\tab12cd3\tWIP 제목",
      "refs/gitch/backup/20261023-163654-pl-wip\tff00ff0\twip",
      "refs/gitch/backup/20261022-090000-fix\t1234567\t제목\t탭",
    ].join("\n");
    expect(parseBackups(out)).toEqual([
      { ref: "refs/gitch/backup/20261023-163654-pl", date: "2026-10-23 16:36:54", reason: "pl", sha: "ab12cd3", subject: "WIP 제목", hasChanges: true },
      { ref: "refs/gitch/backup/20261022-090000-fix", date: "2026-10-22 09:00:00", reason: "fix", sha: "1234567", subject: "제목\t탭", hasChanges: false },
    ]);
  });

  it("버전 · Windows 연결 스크립트 · 경로 · 색 코드", () => {
    expect(versionOf('#!/bin/bash\n# ...\nGITCH_VERSION="3.1.0"\n')).toBe("3.1.0");
    // a gitch installed by 0.4.2-beta.2 or older still says GITSW_VERSION
    expect(versionOf('#!/bin/bash\nGITSW_VERSION="0.4.1"\n')).toBe("0.4.1");
    expect(linkTarget('#!/bin/sh\n# gitch-link: /c/Users/me/AppData/Local/Gitrochi/gitch\nexec "/c/Users/me/AppData/Local/Gitrochi/gitch" "$@"\n')).toBe("/c/Users/me/AppData/Local/Gitrochi/gitch");
    expect(linkTarget('#!/bin/bash\nGITCH_VERSION="3.1.0"\n')).toBeNull();
    expect(fromPosix("/c/Users/me/x")).toBe("C:/Users/me/x");
    expect(fromPosix("C:/Users/me/x")).toBe("C:/Users/me/x");
    expect(plain("\u001b[32m✔\u001b[0m 설치 완료 \n")).toBe("✔ 설치 완료");
  });
});

describe("Commit and gitch preflight", () => {
  const status = (over: Partial<GitchStatus> = {}): GitchStatus => ({ inRepo: true, lockedAccount: null, account: "alice", accountSource: "lock", pushAccount: "alice", ignored: false, ...over });
  const preflight = (...checks: [GitchLevel, string][]): GitchPreflight => ({
    result: checks.some(([level]) => level === "STOP") ? "STOP" : "OK",
    checks: checks.map(([level, code]) => ({ level, code, message: code })),
  });

  it("stops only for the commit author in a repository gitch manages", () => {
    expect(commitStop(status(), preflight(["STOP", "identity"]))?.message).toBe("identity");
    expect(commitStop(status(), preflight(["OK", "identity"], ["STOP", "lock_unknown"]))?.code).toBe("lock_unknown");
  });

  it("lets plain git commit where gitch has no say", () => {
    // no account picked, push-only and repository-state stops
    for (const code of ["no_account", "no_binding", "push_url", "in_progress", "conflicts", "bad_config"]) expect(commitStop(status(), preflight(["STOP", code]))).toBeNull();
    expect(commitStop(status({ ignored: true }), preflight(["STOP", "identity"]))).toBeNull();
    expect(commitStop(null, preflight(["STOP", "identity"]))).toBeNull();
    expect(commitStop(status(), null)).toBeNull();
  });
});
