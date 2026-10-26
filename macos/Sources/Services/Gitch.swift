import Foundation
import CryptoKit

/// gitch — 여러 Git 계정을 섞이지 않게 쓰는 셸 도구(tools/gitch, 예전 이름 gitsw).
/// 앱 안(Contents/Resources/gitch)에 함께 들어 있고 설정 > CLI 에서 셸 명령으로 설치한다.
/// 저장소 화면은 gitch 가 보는 이 저장소의 계정(잠금)과 커밋·push 전 점검을 보여 주고, 계정을 바꿀 수 있다.
/// 저장소 메뉴의 구조 그래프 · 이 브랜치에서 바뀐 의존 · 의존 규칙 검사도 gitch(gitch graph)가 한다.
enum Gitch {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// gitch status --json
    struct Status: Decodable, Equatable {
        let inRepo: Bool
        let lockedAccount: String?
        let account: String?
        /// lock · owner · org · folder · alias · host
        let accountSource: String?
        let pushAccount: String?
        let ignored: Bool?

        private enum CodingKeys: String, CodingKey { case inRepo, lockedAccount, account, accountSource, pushAccount, ignored }

        /// gitch 는 값이 없으면 빈 글자("")를 내므로 nil 로 바꿔 읽는다(잠기지 않은 저장소를 잠긴 것으로 보지 않게)
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) throws -> String? {
                let v = try c.decodeIfPresent(String.self, forKey: key)
                return v?.isEmpty == false ? v : nil
            }
            inRepo = try c.decode(Bool.self, forKey: .inRepo)
            lockedAccount = try text(.lockedAccount)
            account = try text(.account)
            accountSource = try text(.accountSource)
            pushAccount = try text(.pushAccount)
            ignored = try c.decodeIfPresent(Bool.self, forKey: .ignored)
        }
    }

    /// gitch preflight --json (result: OK · WARN · STOP)
    struct Preflight: Decodable, Equatable {
        struct Check: Decodable, Equatable, Hashable {
            let level: String
            let code: String
            let message: String
        }
        let result: String
        let checks: [Check]
    }

    /// gitch list --json 의 계정(rules 는 gitch 가 낸 문구 그대로)
    struct Account: Decodable, Identifiable, Equatable {
        let id: String
        let email: String
        let hosts: String
        let rules: String?
        let sshKey: Bool?
    }

    /// gitch 가 pl · up · sync · fix · undo · amend · rescue 전에 남긴 자동 백업(refs/gitsw/backup/<날짜-시각>-<이유>, 최근 30개)
    struct Backup: Identifiable, Equatable {
        let ref: String
        /// "2026-10-23 16:36:54"
        let date: String
        /// pl · up · sync · fix …
        let reason: String
        let sha: String
        let subject: String
        /// 그때 수정 중이던 파일도 함께 남겼는지
        let hasChanges: Bool
        var id: String { ref }
    }

    /// gitch graph 가 그리는 관계(tools/gitch/README.md 「구조 그래프」)
    enum GraphRelation: String, CaseIterable, Identifiable {
        case files, modules, changes, tree
        var id: String { rawValue }

        var title: String {
            switch self {
            case .files: return String(localized: "File imports")
            case .modules: return String(localized: "Module dependencies")
            case .changes: return String(localized: "Files that change together")
            case .tree: return String(localized: "Folder tree")
            }
        }

        /// 메뉴 항목 설명: 터미널에서 같은 그림을 그리는 명령과 무엇을 읽는지
        var detail: String {
            switch self {
            case .files: return String(localized: "gitch graph files: source files across many languages, with imports, includes and inferred type references.")
            case .modules: return String(localized: "gitch graph modules: targets, packages and dependencies from SwiftPM, Tuist, npm, Cargo, Go, Gradle, Maven, Python, .NET, Composer, Bundler, Pub and CMake.")
            case .changes: return String(localized: "gitch graph changes: files that are often committed together, and how often each one changes.")
            case .tree: return String(localized: "gitch graph tree: folders with their size and number of files.")
            }
        }

        /// gitch graph diff 가 비교하는 관계(같이 바뀌는 파일은 비교하지 않는다)
        static let compared: [GraphRelation] = [.files, .modules, .tree]

        /// 「이 브랜치에서 바뀐 의존」 메뉴 항목 설명
        var diffDetail: String {
            switch self {
            case .files: return String(localized: "gitch graph diff files: imports added and removed on this branch, and cycles that appeared, grew, shrank or went away.")
            case .modules: return String(localized: "gitch graph diff modules: module dependencies added and removed on this branch.")
            case .tree: return String(localized: "gitch graph diff tree: folders whose number of files or size changed on this branch.")
            case .changes: return detail
            }
        }
    }

    /// gitch graph check --format json (tools/gitch/README.md 「규칙 검사」)
    struct GraphCheck: Decodable {
        struct Violation: Decodable, Hashable {
            /// files · modules
            let relation: String
            /// error(위반) · warning(이름만으로 추정한 연결이라 실패로 세지 않는다)
            let severity: String
            /// 어긴 규칙의 줄 번호와 그 줄
            let line: Int
            let rule: String
            /// forbid · layers · no-cycles
            let kind: String
            let source: String?
            let target: String?
            /// no-cycles: 순환을 이루는 노드
            let nodes: [String]?

            var isError: Bool { severity == "error" }
        }
        /// 규칙 파일(저장소 안이면 상대 경로)
        let file: String
        let ok: Bool
        let violations: [Violation]
    }

    /// gitch graph 가 만든 html
    struct GraphPage {
        let file: URL
        /// 로컬 감시 서버가 준비되면 저장 후 자동 갱신되는 주소. Python 이 없으면 파일로 연다.
        var liveURL: URL? = nil
        /// 끝 줄(GRAPH_FILE=… NODES=… EDGES=…)의 노드 수. 그 줄이 없으면 nil
        let nodes: Int?
        /// 그릴 것이 없을 때 gitch 가 낸 안내(⚠ 줄, 문구 그대로)
        let hint: String?
    }

    /// 앱과 버전을 맞추기 전의 gitch graph 최소 버전(옛 CLI 호환용)
    static let graphMinimumVersion = "3.2.0"

    /// 새 CLI 는 기능 표시로 확인한다. 앱 버전과 숫자가 다른 옛 CLI 만 버전으로 판단한다.
    static func supportsGraph(in head: String) -> Bool {
        let lines = head.components(separatedBy: .newlines)
        let scheme = lines.filter { $0.range(of: #"^\s*(?:export\s+)?GITCH_VERSION_SCHEME\b"#, options: .regularExpression) != nil }
        let api = lines.filter { $0.range(of: #"^\s*(?:export\s+)?GITCH_GRAPH_API\b"#, options: .regularExpression) != nil }
        if !scheme.isEmpty || !api.isEmpty {
            return scheme.count == 1 && scheme[0] == #"GITCH_VERSION_SCHEME="gitrochi""#
                && api.count == 1 && api[0].range(of: #"^GITCH_GRAPH_API="[1-9][0-9]*"$"#, options: .regularExpression) != nil
        }
        guard let v = version(in: head), v.range(of: #"^\d+(?:\.\d+){0,3}$"#, options: .regularExpression) != nil else { return false }
        return v.compare(graphMinimumVersion, options: .numeric) != .orderedAscending
    }

    /// 구조 그래프를 그릴 수 없는 이유 — 앱에 든 gitch 가 없거나 그래프 기능이 없다. 그릴 수 있으면 nil.
    /// 설치한 셸 명령은 따로 받은 예전 gitch 일 수 있어서 앱에 든 것만 본다(그래프는 계정 설정이 필요 없다).
    static let graphUnavailableReason: String? = {
        guard let exe = bundled else { return String(localized: "Couldn't find gitch inside Gitrochi.") }
        guard let head = header(at: exe), supportsGraph(in: head) else {
            return String(localized: "The gitch inside Gitrochi doesn't support structure graphs. Update Gitrochi and try again.")
        }
        return nil
    }()

    /// 앱에 든 gitch
    static var bundled: String? { Bundle.main.path(forResource: "gitch", ofType: nil) }
    /// gitch install 이 만드는 셸 명령
    static var link: String { NSHomeDirectory() + "/bin/gitch" }
    /// 예전 이름 — gitch install 이 같은 파일로 이어 두고, 그 전에 gitsw 로 깔았으면 그것만 있다
    static var legacyLink: String { NSHomeDirectory() + "/bin/gitsw" }
    /// 설정 파일은 예전 이름의 폴더 그대로(기존 설치와 같은 설정을 쓰게)
    static var configFile: String { NSHomeDirectory() + "/.config/gitsw/config" }
    /// 계정을 하나라도 더했는지(gitch add) — 없으면 install 도 저장소 점검도 할 수 없다
    static var hasConfig: Bool { FileManager.default.fileExists(atPath: configFile) }

    /// 셸 명령이 가리키는 실제 파일(~/bin/gitch, 없으면 예전 ~/bin/gitsw). 설치하지 않았으면 nil
    static var installed: String? {
        let fm = FileManager.default
        guard let path = [link, legacyLink].first(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// 셸 명령 이름(~/bin/gitch 또는 예전 ~/bin/gitsw)
    static var installedName: String? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: link) { return "~/bin/gitch" }
        return fm.isExecutableFile(atPath: legacyLink) ? "~/bin/gitsw" : nil
    }

    /// 설치된 셸 명령이 이 앱에 든 gitch 인지(아니면 따로 받은 gitch 나 예전 gitsw)
    static var installedIsBundled: Bool {
        guard let i = installed, let b = bundled else { return false }
        return i == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    /// 저장소 점검에 쓸 gitch: 설치된 것(따로 받은 것일 수도), 없으면 앱에 든 것
    static var executable: String? { installed ?? bundled }

    /// 파일 머리의 GITSW_VERSION="x.y.z"(변수 이름은 예전 그대로)
    static func version(at path: String) -> String? {
        guard let head = header(at: path) else { return nil }
        return version(in: head)
    }

    private static func header(at path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        return String(decoding: h.readData(ofLength: 4096), as: UTF8.self)
    }

    private static func version(in head: String) -> String? {
        guard let start = head.range(of: "GITSW_VERSION=\"")?.upperBound,
              let end = head[start...].firstIndex(of: "\"") else { return nil }
        return String(head[start..<end])
    }

    /// 앱을 Finder 에서 켜면 PATH 가 짧다 — gitch 가 부르는 git·gh·jq 를 찾게 흔한 위치를 앞에 둔다
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let git = ToolPaths.shared.get(.git).map { ($0 as NSString).deletingLastPathComponent }
        env["PATH"] = ([git, NSHomeDirectory() + "/bin", "/opt/homebrew/bin", "/usr/local/bin"].compactMap { $0 }
                       + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        return env
    }

    static func status(in repo: URL) async -> Status? { await json(["status", "--json"], in: repo) }

    /// fetch 면 원격을 받아 받을 커밋까지 본다(몇 초). 아니면 지금 있는 원격 정보로만(0.2초 안팎).
    static func preflight(in repo: URL, fetch: Bool) async -> Preflight? {
        await json(["preflight", "--json"] + (fetch ? [] : ["--no-fetch"]), in: repo)
    }

    static func accounts() async -> [Account] {
        struct List: Decodable { let accounts: [Account] }
        let list: List? = await json(["list", "--json"], in: URL(fileURLWithPath: NSHomeDirectory()))
        return list?.accounts ?? []
    }

    /// gitch 명령을 실행하고, 실패하면 gitch 가 낸 문구로 던진다. 성공하면 출력(색 코드 뺀 것)
    @discardableResult
    static func run(_ args: [String], in repo: URL, timeout: TimeInterval = 120) async throws -> String {
        guard let exe = executable else { throw Failure(message: String(localized: "Couldn't find gitch inside Gitrochi.")) }
        let r = try await Shell.run("/bin/bash", [exe] + args, cwd: repo, env: environment, timeout: timeout)
        let out = plain(r.output + (r.stderr.isEmpty ? "" : "\n" + r.stderr))
        guard r.status == 0 else { throw Failure(message: out.isEmpty ? "exit \(r.status)" : out) }
        return out
    }

    /// 종료 코드와 출력을 그대로(확인이 필요하면 gitch 는 2 로 끝나며 무엇을 할지 목록을 낸다)
    static func runRaw(_ args: [String], in repo: URL, timeout: TimeInterval = 120) async throws -> (status: Int32, output: String) {
        guard let exe = executable else { throw Failure(message: String(localized: "Couldn't find gitch inside Gitrochi.")) }
        let r = try await Shell.run("/bin/bash", [exe] + args, cwd: repo, env: environment, timeout: timeout)
        return (r.status, plain(r.output + (r.stderr.isEmpty ? "" : "\n" + r.stderr)))
    }

    /// 자동 백업 목록(gitch rescue 와 같은 순서 — 최근 것이 1번)
    static func backups(in repo: URL) async -> [Backup] {
        let prefix = "refs/gitsw/backup/"
        guard let r = try? await Git.run(["for-each-ref", "--sort=-refname", "--format=%(refname)%09%(objectname:short)%09%(subject)", prefix], in: repo) else { return [] }
        let rows = r.output.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init) }
        let refs = Set(rows.compactMap(\.first))
        return rows.compactMap { row in
            guard row.count == 3, !row[0].hasSuffix("-wip") else { return nil }
            let name = String(row[0].dropFirst(prefix.count))
            guard name.count > 16 else { return nil }
            let ts = Array(name)
            let date = "\(String(ts[0..<4]))-\(String(ts[4..<6]))-\(String(ts[6..<8])) \(String(ts[9..<11])):\(String(ts[11..<13])):\(String(ts[13..<15]))"
            return Backup(ref: row[0], date: date, reason: String(name.dropFirst(16)), sha: row[1], subject: row[2], hasChanges: refs.contains(row[0] + "-wip"))
        }
    }

    /// gitch use <계정>: 이 저장소의 커밋 작성자와 원격 주소(그 계정의 SSH 별칭)를 바꾸고 그 계정으로 잠근다
    static func use(_ account: String, in repo: URL) async throws {
        try await run(["use", account], in: repo, timeout: 60)
    }

    /// 앱에 든 gitch 로 `gitch install`: ~/bin/gitch(와 예전 이름 ~/bin/gitsw) 연결, ~/.zshrc, git 전역 훅·규칙, AI 도구 규칙
    static func install() async throws -> String {
        guard let exe = bundled else { throw Failure(message: String(localized: "Couldn't find gitch inside Gitrochi.")) }
        // 응용 프로그램 폴더 밖(디스크 이미지 · 다운로드 폴더 · 임시 위치)의 앱에 연결하면 디스크를 꺼내거나 앱을 옮길 때 끊긴다
        // (gitch install 도 같은 곳을 거부하지만, 번역된 안내를 보이려고 먼저 확인한다)
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().path.lowercased()
        guard ["/Applications/", NSHomeDirectory() + "/Applications/"].contains(where: { app.hasPrefix($0.lowercased()) }) else {
            throw Failure(message: String(localized: "Gitrochi is running from a temporary location. Move it to the Applications folder, open it again, then install gitch."))
        }
        let r = try await Shell.run("/bin/bash", [exe, "install"], cwd: URL(fileURLWithPath: NSHomeDirectory()), env: environment, timeout: 180)
        let out = plain(r.output + (r.stderr.isEmpty ? "" : "\n" + r.stderr))
        guard r.status == 0 else { throw Failure(message: out.isEmpty ? "exit \(r.status)" : out) }
        return out
    }

    /// Terminal 새 창에서 gitch 명령(add · setup · doctor 처럼 묻거나 길게 보여 주는 것). path 를 주면 그 저장소에서.
    static func openInTerminal(_ args: [String], in path: String? = nil) throws {
        guard let exe = executable else { throw Failure(message: String(localized: "Couldn't find gitch inside Gitrochi.")) }
        try Launcher.run("/bin/bash", args: [exe] + args, in: path ?? NSHomeDirectory())
    }

    /// `gitch graph <관계> --format html --out <임시 파일> --no-open` — CDN 없는 한 페이지를 만든다.
    /// modules 는 Package.swift 마다 swift package describe 로 몇 초, 큰 저장소의 files 도 몇 초 걸린다(프로세스를 기다리고 출력을 읽는 일은 메인 스레드 밖에서).
    static func graph(_ relation: GraphRelation, in repo: URL, precise: Bool = false) async throws -> GraphPage {
        let file = graphFile(precise ? "files-precise" : relation.rawValue, in: repo)
        let r = try await runGraph([relation.rawValue] + (precise ? ["--precise"] : []) + ["--format", "html", "--out", file.path, "--no-open"], in: repo)
        var page = graphPage(file, result: r)
        page.liveURL = await graphWatchURL(precise ? "precise" : relation.rawValue, file: file, in: repo)
        return page
    }

    static func affectedGraph(base: String? = nil, in repo: URL) async throws -> GraphPage {
        let file = graphFile("affected", in: repo)
        let r = try await runGraph(["affected"] + (base.map { ["--base", $0] } ?? []) + ["--format", "html", "--out", file.path, "--no-open"], in: repo)
        var page = graphPage(file, result: r)
        if base == nil { page.liveURL = await graphWatchURL("affected", file: file, in: repo) }
        return page
    }

    /// 작업 트리와 섞이지 않도록 CLI 가 HEAD 와 스테이지만 별도 스냅샷으로 분석한다.
    static func commitReview(in repo: URL) async throws -> CommitReviewReport {
        let result = try await runGraph(["review", "--json"], in: repo)
        do { return try CommitReviewReport.decode(result.data) }
        catch { throw Failure(message: String(localized: "Couldn't read the staged change analysis. Update Gitrochi and try again.")) }
    }

    /// 파일 감시로 index 가 바뀌면 비싼 의존 분석 대신 이 값만 다시 확인한다.
    static func commitReviewStamp(in repo: URL) async throws -> CommitReviewStamp {
        let result = try await runGraph(["review", "--stamp", "--json"], in: repo)
        do { return try CommitReviewStamp.decode(result.data) }
        catch { throw Failure(message: String(localized: "Couldn't verify whether the staged change analysis is current. Analyze again.")) }
    }

    /// 현재 스테이지만 담은 리뷰 그래프. 감시 서버는 작업 트리까지 포함하므로 붙이지 않는다.
    static func commitReviewPage(in repo: URL) async throws -> URL {
        let file = graphFile("staged-review", in: repo)
        let result = try await runGraph(["review", "--format", "html", "--out", file.path, "--no-open"], in: repo)
        guard plain(result.output).contains("GRAPH_FILE=") else { throw graphFailure(result) }
        return file
    }

    private static func graphWatchURL(_ relation: String, file: URL, in repo: URL) async -> URL? {
        struct Watch: Decodable { let url: String }
        guard let r = try? await runGraph(["watch", relation, "--out", file.path, "--no-open", "--detach", "--json"], in: repo),
              let result = try? JSONDecoder().decode(Watch.self, from: r.data), let url = URL(string: result.url),
              url.scheme == "http", url.host == "127.0.0.1", url.port != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func graphPage(_ file: URL, result r: GitResult) -> GraphPage {
        let lines = plain(r.output).components(separatedBy: "\n")
        // 경로에 빈칸이 있을 수 있어 NODES= 는 끝 줄의 뒤에서 찾는다
        let summary = lines.last { $0.hasPrefix("GRAPH_FILE=") }
        let nodes = summary.flatMap { s in s.range(of: " NODES=", options: .backwards).flatMap { Int(s[$0.upperBound...].prefix { $0.isNumber }) } }
        let hint = lines.first { $0.hasPrefix("⚠") }.map { $0.dropFirst().trimmingCharacters(in: .whitespaces) }
        return GraphPage(file: file, nodes: nodes, hint: hint)
    }

    /// `gitch graph diff [--base 기준...] <관계> --format html --out <임시 파일> --no-open` — 기준과 이 브랜치가 갈라진 곳과 지금 작업 트리(커밋하지 않은 바꿈 포함)의
    /// 의존을 비교해 더한 것은 초록, 뺀 것은 빨간 점선으로 그린 페이지. 기준이 nil 이면 gitch 가 고른다(기본 브랜치와 갈라진 곳).
    /// 기준... 은 gitch 가 갈라진 곳(merge-base)을 찾고 페이지에는 기준 이름을 적는다 — 기준 브랜치가 그 뒤로 앞서 나가도 그 커밋이 뺀 것으로 보이지 않게.
    /// 기준 커밋을 임시 폴더에 풀어 같은 방법으로 한 번 더 읽으므로 큰 저장소는 몇 초 걸린다.
    static func graphDiff(_ relation: GraphRelation, base: String?, in repo: URL) async throws -> URL {
        let file = graphFile("\(relation.rawValue)-diff", in: repo)
        let since = base.map { ["--base", "\($0)..."] } ?? []
        try await runGraph(["diff"] + since + [relation.rawValue, "--format", "html", "--out", file.path, "--no-open"], in: repo)
        return file
    }

    /// gitch graph check 가 읽는 규칙 파일
    static func graphRulesFile(in repo: URL) -> URL {
        repo.appendingPathComponent(".gitch", isDirectory: true).appendingPathComponent("graph.rules")
    }

    /// 규칙 파일의 규칙 줄 수(# 뒤 주석 · 빈 줄 · [files] 같은 절 머리는 빼고). --init 이 만든 예시는 모두 주석이라 0
    static func graphRuleCount(in repo: URL) -> Int {
        guard let text = try? String(contentsOf: graphRulesFile(in: repo), encoding: .utf8) else { return 0 }
        return text.split(whereSeparator: \.isNewline).filter { line in
            let rule = line.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            return !rule.isEmpty && !(rule.hasPrefix("[") && rule.hasSuffix("]"))
        }.count
    }

    /// `gitch graph check --format json`. 위반이 있으면 gitch 는 1 로 끝나지만 실패가 아니다(결과 JSON 을 낸다).
    /// 규칙 파일에 틀린 줄이 있으면 JSON 없이 1 로 끝나고, 틀린 줄을 표준오류에 낸다.
    static func graphCheck(in repo: URL) async throws -> GraphCheck {
        let r = try await runGraph(["check", "--format", "json"], in: repo, ok: [0, 1])
        guard let result = try? JSONDecoder().decode(GraphCheck.self, from: r.data) else { throw graphFailure(r) }
        return result
    }

    /// `gitch graph check --format html --out <임시 파일> --no-open` — 규칙을 어긴 연결을 빨갛게 그린 페이지(위반이 있어 1 로 끝나도 만든다)
    static func graphCheckPage(in repo: URL) async throws -> URL {
        let file = graphFile("check", in: repo)
        let r = try await runGraph(["check", "--format", "html", "--out", file.path, "--no-open"], in: repo, ok: [0, 1])
        guard plain(r.output).contains("GRAPH_FILE=") else { throw graphFailure(r) }
        return file
    }

    /// `gitch graph check --init` — 예시(모두 # 주석)가 든 규칙 파일을 만든다
    static func graphRulesInit(in repo: URL) async throws {
        try await runGraph(["check", "--init"], in: repo)
    }

    /// 앱에 든 gitch 로 `gitch graph …`. 종료 코드가 ok 에 없으면 gitch 가 낸 까닭으로 던진다.
    /// 설치한 셸 명령은 따로 받은 예전 gitch 일 수 있어서 앱에 든 것만 쓴다(그래프는 계정 설정이 필요 없다).
    @discardableResult
    private static func runGraph(_ args: [String], in repo: URL, ok: Set<Int32> = [0]) async throws -> GitResult {
        if let reason = graphUnavailableReason { throw Failure(message: reason) }
        guard let exe = bundled else { throw Failure(message: String(localized: "Couldn't find gitch inside Gitrochi.")) }
        var graphEnvironment = environment
        graphEnvironment["GITCH_GRAPH_LANG"] = AppLanguage.graphCode
        let r = try await Shell.run("/bin/bash", [exe, "graph"] + args, cwd: repo, env: graphEnvironment, timeout: 600)
        guard ok.contains(r.status) else { throw graphFailure(r) }
        return r
    }

    /// 왜 못 했는지는 gitch 가 표준오류에 낸다
    private static func graphFailure(_ r: GitResult) -> Failure {
        let err = plain(r.stderr), out = plain(r.output)
        return Failure(message: !err.isEmpty ? err : !out.isEmpty ? out : "exit \(r.status)")
    }

    /// 임시 폴더의 gitch-graph/(터미널의 gitch graph 가 쓰는 곳)에 <저장소 폴더>-<이름>-<경로 해시>.html(이름: 관계 · <관계>-diff · check).
    /// 다시 그리면 덮어쓰고, 폴더 이름이 같은 다른 저장소 · 워크트리와는 해시로 갈린다.
    private static func graphFile(_ name: String, in repo: URL) -> URL {
        let hash = SHA256.hash(data: Data(repo.path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("gitch-graph", isDirectory: true)
            // Separate watcher identities so an earlier language cannot overwrite this page.
            .appendingPathComponent("\(repo.lastPathComponent)-\(name)-\(AppLanguage.graphCode)-\(hash).html")
    }

    private static func json<T: Decodable>(_ args: [String], in repo: URL) async -> T? {
        guard hasConfig, let exe = executable,
              let r = try? await Shell.run("/bin/bash", [exe] + args, cwd: repo, env: environment, timeout: 60) else { return nil }
        // preflight 는 STOP 이면 종료 코드가 1 이어도 JSON 을 낸다
        return try? JSONDecoder().decode(T.self, from: r.data)
    }

    /// 터미널 색 코드를 뺀다
    private static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
