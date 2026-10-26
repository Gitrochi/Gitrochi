// 자동 점검용 가짜 AI 서버(OpenAI 호환): /v1/models, /v1/chat/completions
import fs from "node:fs";
import http from "node:http";

const port = Number(process.argv[2] ?? 18080);
// 자동 업데이트 점검용: 설치 파일과 그 서명(.sig)
const updateFile = process.argv[3];
const updateSig = process.argv[4] ? fs.readFileSync(process.argv[4], "utf8").trim() : "";
// 서명에 버전이 적혀 있으면(tauri build 가 만든 서명) 그 버전을 알린다 — 다르면 업데이터가 거절한다
const signedVersion = updateSig ? (Buffer.from(updateSig, "base64").toString("utf8").match(/version:(\S+)/) ?? [])[1] : undefined;
const manifest = (sig) => {
  const url = `http://127.0.0.1:${port}/update/file`;
  const p = { signature: sig, url };
  return JSON.stringify({
    version: signedVersion ?? "9.9.9",
    notes: "자동 점검용 가짜 업데이트",
    pub_date: "2026-10-20T00:00:00Z",
    platforms: { "windows-x86_64": p, "darwin-aarch64": p, "darwin-x86_64": p },
  });
};
const ciCalls = [];
http
  .createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      res.setHeader("content-type", "application/json");
      if (req.url === "/v1/models") return res.end(JSON.stringify({ data: [{ id: "mock-model" }] }));
      if (updateFile && req.url === "/update/latest.json") return res.end(manifest(updateSig));
      // 서명을 다른 파일 것으로 바꿔치기한 목록 — 설치를 거부해야 한다
      if (updateFile && req.url === "/update/tampered.json") {
        const other = Buffer.from(Buffer.from(updateSig, "base64").toString("utf8").replace(/file:\S+/, "file:other")).toString("base64");
        return res.end(manifest(other));
      }
      // 맥 업데이트 점검용: MOCK_FILES_DIR 의 파일을 그대로 내준다
      if (process.env.MOCK_FILES_DIR && req.url.startsWith("/files/")) {
        const f = process.env.MOCK_FILES_DIR + "/" + decodeURIComponent(req.url.slice(7)).replace(/\.\./g, "");
        if (fs.existsSync(f)) {
          res.setHeader("content-type", "application/octet-stream");
          return res.end(fs.readFileSync(f));
        }
      }
      if (updateFile && req.url === "/update/file") {
        res.setHeader("content-type", "application/octet-stream");
        return res.end(fs.readFileSync(updateFile));
      }
      // CI/CD 점검용 가짜 GitLab(/api/v4/projects/g%2Fp/…)·GitHub(/gh/repos/o/r/…). 받은 실행 요청은 /ci/calls 로 확인
      if (req.url === "/ci/calls") return res.end(JSON.stringify(ciCalls));
      if (req.url.startsWith("/api/v4/projects/g%2Fp/") || req.url.startsWith("/gh/repos/o/r/")) {
        const u = req.url.split("?")[0];
        if (req.method === "POST") ciCalls.push({ url: u, body: body ? JSON.parse(body) : null, token: req.headers["private-token"] ?? req.headers.authorization });
        const sha = "1111111111111111111111111111111111111111";
        if (u.endsWith("/pipelines"))
          return res.end(JSON.stringify([{ id: 11, iid: 3, sha, ref: "main", status: "success", source: "push", created_at: "2026-10-20T00:00:00Z", web_url: "http://x/p/11", user: { username: "dev" } }]));
        if (u.endsWith("/pipelines/11/jobs"))
          return res.end(
            JSON.stringify([
              { id: 102, name: "deploy-prod", stage: "deploy", status: "manual", web_url: "http://x/j/102", allow_failure: true, duration: null },
              { id: 101, name: "build", stage: "build", status: "success", web_url: "http://x/j/101", allow_failure: false, duration: 42.4 },
            ]),
          );
        if (u.endsWith("/jobs/102/play")) return res.end(JSON.stringify({ id: 102, status: "pending" }));
        if (u.endsWith("/pipeline")) return res.end(JSON.stringify({ id: 12, status: "created" }));
        if (u.endsWith("/actions/workflows"))
          return res.end(JSON.stringify({ workflows: [{ id: 7, name: "Deploy", path: ".github/workflows/deploy.yml", state: "active" }, { id: 8, name: "CI", path: ".github/workflows/ci.yml", state: "active" }] }));
        if (u.endsWith("/contents/.github/workflows/deploy.yml")) {
          const yml = "on:\n  workflow_dispatch:\n    inputs:\n      target:\n        description: 배포 대상\n        type: choice\n        options: [staging, production]\n        required: true\n";
          return res.end(JSON.stringify({ content: Buffer.from(yml).toString("base64").replace(/(.{60})/g, "$1\n") }));
        }
        if (u.endsWith("/contents/.github/workflows/ci.yml")) return res.end(JSON.stringify({ content: Buffer.from("on: [push]\n").toString("base64") }));
        // PR·MR 리뷰(번호 5)
        const at = "2026-10-20T01:00:00Z";
        if (u.endsWith("/pulls/5")) return res.end(JSON.stringify({ head: { sha: "review-head" }, base: { sha: "review-base" } }));
        if (u.endsWith("/merge_requests/5")) return res.end(JSON.stringify({ diff_refs: { head_sha: "review-head", base_sha: "review-base", start_sha: "review-start" } }));
        if (u.endsWith("/issues/5/comments") && req.method === "GET") return res.end(JSON.stringify([{ id: 1, user: { login: "kim" }, body: "좋아요", created_at: at }]));
        if (u.endsWith("/pulls/5/comments")) return res.end(JSON.stringify([{ id: 2, user: { login: "kim" }, body: "여기 오타", created_at: "2026-10-20T02:00:00Z", path: "src/a.ts", line: 3 }]));
        if (u.endsWith("/pulls/5/reviews") && req.method === "GET")
          return res.end(
            JSON.stringify([
              { id: 3, user: { login: "lee" }, state: "APPROVED", body: "", submitted_at: "2026-10-20T03:00:00Z" },
              { id: 4, user: { login: "park" }, state: "CHANGES_REQUESTED", body: "테스트 추가", submitted_at: "2026-10-20T04:00:00Z" },
            ]),
          );
        if (u.endsWith("/pulls/5/files"))
          return res.end(JSON.stringify([{ filename: "src/a.ts", status: "modified", additions: 1, deletions: 1, patch: "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c" }]));
        if (u.endsWith("/merge_requests/5/discussions"))
          return res.end(
            JSON.stringify([
              { id: "discussion-10", notes: [{ id: 10, author: { username: "kim" }, body: "LGTM", created_at: at, system: false }, { id: 11, author: { username: "kim" }, body: "added 1 commit", created_at: at, system: true }] },
              { id: "discussion-12", notes: [{ id: 12, author: { username: "lee" }, body: "여기 확인", created_at: "2026-10-20T02:00:00Z", system: false, position: { new_path: "src/a.ts", new_line: 3 } }] },
            ]),
          );
        if (u.endsWith("/merge_requests/5/approvals")) return res.end(JSON.stringify({ approved_by: [{ user: { username: "lee" } }], approvals_left: 1 }));
        if (u.endsWith("/merge_requests/5/diffs")) return res.end(JSON.stringify([{ old_path: "src/a.ts", new_path: "src/a.ts", diff: "@@ -1 +1 @@\n-a\n+b\n" }]));
        if (req.method === "POST" && /\/(issues\/5\/comments|pulls\/5\/reviews|merge_requests\/5\/(notes|approve|unapprove))$/.test(u)) return res.end("{}");
        if (u.endsWith("/actions/workflows/7/dispatches")) {
          res.statusCode = 204;
          return res.end();
        }
      }
      if (req.url === "/v1/chat/completions" && req.method === "POST") {
        const j = JSON.parse(body || "{}");
        const sys = j.messages?.[0]?.content ?? "";
        const user = j.messages?.[1]?.content ?? "";
        // 커밋 메시지 요청이면 diff 안의 파일 이름을 넣어 돌려준다(요청이 제대로 왔는지 확인용)
        const file = (user.match(/b\/(\S+)/) ?? [])[1] ?? "unknown";
        // 사용자 규칙이 함께 왔는지 확인용: 규칙에 RULE-TEST 가 있으면 "Rule:" 로 시작
        const prefix = sys.includes("RULE-TEST") ? "Rule: " : "";
        let text = "OK";
        if (sys.includes("split a set of uncommitted")) {
          // 나눠서 커밋: 확장자별로 묶는다
          const files = [...user.matchAll(/^- (\S+)/gm)].map((m) => m[1]);
          const byExt = {};
          for (const f of files) (byExt[f.split(".").pop()] ??= []).push(f);
          text = JSON.stringify({ commits: Object.entries(byExt).map(([ext, fs]) => ({ message: `${prefix}${ext} 파일 정리`, files: fs })) });
        } else if (sys.includes("commit messages")) {
          text = `${prefix}가짜 AI 커밋: ${file}\n\n모델 ${j.model}`;
        }
        return res.end(JSON.stringify({ choices: [{ message: { content: text } }] }));
      }
      res.statusCode = 404;
      res.end(JSON.stringify({ error: { message: "not found" } }));
    });
  })
  .listen(port, "127.0.0.1", () => console.log(`mock AI on ${port}`));
