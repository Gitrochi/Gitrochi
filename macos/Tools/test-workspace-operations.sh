#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum Provider { case github, gitlab }
struct RepoTarget { let provider: Provider; let host: String; let path: String }
struct PullRequest { let number: Int; let title: String; let author: String; let source: String; let target: String; let url: String; let isDraft: Bool; let updated: Date?; let body: String; let headSHA: String?; let fromFork: Bool }
enum Hosting {
    static var handler: (URLRequest) throws -> Data = { _ in fatalError("Unexpected request") }
    static func request(_ p: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var r = URLRequest(url: URL(string: url)!); r.httpMethod = method
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }; return r
    }
    static func data(_ r: URLRequest) async throws -> Data { try handler(r) }
    static func projectID(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "%2F") }
    static func date(_ s: String?) -> Date? { nil }
}
struct RemoteRepo { let fullName:String;let cloneURL:String;let isPrivate:Bool;let summary:String? }
@main struct WorkspaceOperationTests {
    @MainActor static func main() async throws {
        func json(_ value:Any)throws->Data{try JSONSerialization.data(withJSONObject:value)}
        let gh=ReviewAccess(target:RepoTarget(provider:.github,host:"github.com",path:"team/repo"),token:"fixture-token",apiBase:"https://api.github.com",me:"me")
        let gl=ReviewAccess(target:RepoTarget(provider:.gitlab,host:"gitlab.example",path:"team/repo"),token:"fixture-token",apiBase:"https://gitlab.example/api/v4",me:"me")
        var calls:[URLRequest]=[]
        Hosting.handler={r in calls.append(r);return try json(["items":[["number":7,"title":"Result","state":"closed","user":["login":"me"]]],"total_count":70])}
        let (items,more)=try await WorkspaceOperations.issues(gh,scope:"closed",search:"fix",page:2)
        precondition(items.count==1&&items[0].number==7&&more)
        let q=URLComponents(url:calls[0].url!,resolvingAgainstBaseURL:false)!.queryItems!
        precondition(q.first{$0.name=="q"}!.value!.contains("repo:team/repo is:issue is:closed"));precondition(q.first{$0.name=="page"}!.value=="2")
        Hosting.handler={r in calls.append(r);return try json([["iid":8,"title":"Task","description":"Body","state":"opened","author":["username":"me"]]])}
        let result=try await WorkspaceOperations.issues(gl,scope:"open",search:"nested",page:1)
        precondition(result.0[0].body=="Body"&&calls.last!.url!.absoluteString.contains("team%2Frepo/issues"))
        Hosting.handler={r in calls.append(r);return try json(["iid":8,"title":"Saved","state":"opened"])}
        _=try await WorkspaceOperations.saveIssue(gl,title:" Title ",body:"Description")
        precondition(calls.last!.httpMethod=="POST")
        let payload=try JSONSerialization.jsonObject(with:calls.last!.httpBody!) as! [String:Any]
        precondition(payload["title"] as? String=="Title"&&payload["description"] as? String=="Description")
        _=try await WorkspaceOperations.saveIssue(gh,title:"Edit",body:"Body",number:8)
        precondition(calls.last!.httpMethod=="PATCH"&&calls.last!.url!.path.hasSuffix("/issues/8"))
        let count=calls.count;var stale=gh;stale.isCurrent={false}
        do{_=try await WorkspaceOperations.saveIssue(stale,title:"Title",body:"");fatalError("stale write")}catch{}
        do{_=try await WorkspaceOperations.saveIssue(gh,title:" ",body:"");fatalError("empty title")}catch{}
        precondition(calls.count==count)
        Hosting.handler={r in calls.append(r);return try json(["items":[["full_name":"team/remote","clone_url":"https://github.com/team/remote.git","private":true]],"total_count":31])}
        let repos=try await WorkspaceOperations.repositories(gh,search:"remote",page:1)
        precondition(repos.0[0].isPrivate&&repos.1&&calls.last!.url!.host=="api.github.com")
        Hosting.handler={r in calls.append(r);return try json([])}
        _=try await WorkspaceOperations.repositories(gl,search:"",page:1)
        precondition(calls.last!.url!.absoluteString.contains("membership=true"))
        let ghEndpoint=try WorkspaceCILog.endpoint(gh,job:9).absoluteString
        precondition(ghEndpoint=="https://api.github.com/repos/team/repo/actions/jobs/9/logs")
        let glEndpoint=try WorkspaceCILog.endpoint(gl,job:9).absoluteString
        precondition(glEndpoint=="https://gitlab.example/api/v4/projects/team%2Frepo/jobs/9/trace")
        let redacted=WorkspaceCILog.redact("\u{1b}[31mfixture-token\u{1b}[0m\nAuthorization: Bearer leaked\npassword=abc\nghp_abcdefghijklmnopqrstu",token:"fixture-token")
        precondition(!redacted.contains("fixture-token") && !redacted.contains("leaked") && !redacted.contains("abc") && !redacted.contains("ghp_") && !redacted.contains("\u{1b}"))
        Hosting.handler={r in calls.append(r);return try json([["id":"14","unread":true,"subject":["title":"Review","type":"PullRequest","url":"https://api.github.com/repos/team/other/pulls/9"],"repository":["full_name":"team/other"]]])}
        let accountInbox=try await AccountWorkAPI.page(gh,kind:"inbox",page:1)
        precondition(accountInbox.0.count==1&&accountInbox.0[0].repository=="team/other"&&accountInbox.0[0].url=="https://github.com/team/other/pull/9")
        Hosting.handler={r in calls.append(r);return try json(["items":[["id":8,"number":7,"title":"Work","html_url":"https://github.com/org/other/pull/7","repository_url":"https://api.github.com/repos/org/other","state":"open"]],"total_count":31])}
        let globalWork=try await AccountWorkAPI.page(gh,kind:"assignedRequests",page:1)
        precondition(globalWork.0[0].repository=="org/other"&&globalWork.1)
        let globalQuery=URLComponents(url:calls.last!.url!,resolvingAgainstBaseURL:false)!.queryItems!
        precondition(globalQuery.first{$0.name=="q"}!.value!.contains("assignee:me"))
        Hosting.handler={r in calls.append(r);return try json([["id":21,"target_type":"MergeRequest","target_url":"https://gitlab.example/group/other/-/merge_requests/4","target":["iid":4,"title":"Review"],"project":["path_with_namespace":"group/other"]],["id":22,"target_url":"https://other.example/group/repo/-/issues/2","project":["path_with_namespace":"group/repo"]]])}
        let globalTodos=try await AccountWorkAPI.page(gl,kind:"inbox",page:1)
        precondition(globalTodos.0.count==1&&globalTodos.0[0].unread&&globalTodos.0[0].readID=="21")
        Hosting.handler={r in calls.append(r);return Data()}
        try await AccountWorkAPI.read(gl,item:globalTodos.0[0]);precondition(calls.last!.httpMethod=="POST"&&calls.last!.url!.path.hasSuffix("/todos/21/mark_as_done"))
        let accountItem=AccountWorkAPI.item(gl,["id":21,"target_url":"https://gitlab.example/group/other/-/issues/4","target":["iid":4,"title":"Private account notification"],"project":["path_with_namespace":"group/other"]],kind:"inbox",accountID:"profile-a")!
        let beforeWrongRead=calls.count
        do{try await AccountWorkAPI.read(gl,item:accountItem,accountID:"profile-b");fatalError("different profile accepted")}catch{}
        let otherAccount=ReviewAccess(target:gl.target,token:"other-token",apiBase:gl.apiBase,me:"another-user")
        do{try await AccountWorkAPI.read(otherAccount,item:accountItem,accountID:"profile-a");fatalError("different principal accepted")}catch{}
        precondition(calls.count==beforeWrongRead)
        let jsonSecrets = #"{"password":"escaped\"secret","API_TOKEN":"json-token","database_secret":"secret with spaces","normal":"keep"}"#
        let maskedJSON=WorkspaceCILog.redact(jsonSecrets)
        let maskedValues=try JSONSerialization.jsonObject(with:Data(maskedJSON.utf8)) as! [String:String]
        precondition(maskedValues["password"]=="[redacted]"&&maskedValues["API_TOKEN"]=="[redacted]"&&maskedValues["database_secret"]=="[redacted]"&&maskedValues["normal"]=="keep")
        let maskedEnvironment=WorkspaceCILog.redact("MY_SECRET=secret-one\nDB_PASSWORD = 'secret with spaces'\nPIPELINE_ACCESS_TOKEN=another-token\nNORMAL=keep")
        precondition(!maskedEnvironment.contains("secret-one") && !maskedEnvironment.contains("secret with spaces") && !maskedEnvironment.contains("another-token") && maskedEnvironment.contains("NORMAL=keep"))
        let publicKey="-----BEGIN PUBLIC KEY-----\npublic-material\n-----END PUBLIC KEY-----"
        for kind in ["PRIVATE KEY","RSA PRIVATE KEY","EC PRIVATE KEY","DSA PRIVATE KEY","OPENSSH PRIVATE KEY","ENCRYPTED PRIVATE KEY","PGP PRIVATE KEY BLOCK"] {
            let maskedPEM=WorkspaceCILog.redact("-----BEGIN \(kind)-----\nprivate-material\n-----END \(kind)-----\n\(publicKey)")
            precondition(!maskedPEM.contains("private-material") && maskedPEM.contains(publicKey))
            precondition(WorkspaceCILog.redact("-----BEGIN \(kind)-----\ntruncated-private-material")=="[redacted private key]")
        }
        precondition(WorkspaceCILog.redact("fi\u{1b}[31mxture-token",token:"fixture-token")=="[redacted]")
        print("Workspace operations: issue search/CRUD/context guards, remote repository scope/pagination CI endpoint/redaction and account-wide inbox/work checks passed")
    }
}
SWIFT
swiftc -swift-version 5 -parse-as-library "$ROOT/Sources/Services/Collaboration.swift" "$ROOT/Sources/Services/WorkspaceOperations.swift" "$ROOT/Sources/Services/WorkspaceCILog.swift" "$ROOT/Sources/Services/AccountWork.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test"
"$TASK_TMP/test"
