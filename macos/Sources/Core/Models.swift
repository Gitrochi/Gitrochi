import Foundation

// MARK: - Commits

struct Commit: Identifiable, Hashable {
    /// 그래프 맨 위 "작업 중인 변경" 가상 행의 ID
    static let wipID = "__WORKING_TREE__"

    let id: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date
    let subject: String
    /// 본문 첫 줄(그래프에서 제목 뒤에 흐리게)
    var body: String = ""

    var short: String { String(id.prefix(7)) }
    var isWIP: Bool { id == Commit.wipID }
    var isMerge: Bool { parents.count > 1 }

    static func wip(parent: String?) -> Commit {
        Commit(id: wipID, parents: parent.map { [$0] } ?? [], author: "", email: "", date: Date(), subject: "")
    }

    /// Rows for another worktree's uncommitted changes (GitKraken shows one per worktree)
    private static let worktreeWIPPrefix = "__WORKTREE__:"

    static func worktreeWIP(path: String, parent: String) -> Commit {
        Commit(id: worktreeWIPPrefix + path, parents: [parent], author: "", email: "", date: Date(), subject: "")
    }

    /// The worktree path of such a row, otherwise nil
    var wipWorktree: String? { id.hasPrefix(Commit.worktreeWIPPrefix) ? String(id.dropFirst(Commit.worktreeWIPPrefix.count)) : nil }
    /// Uncommitted changes of this or another worktree, not a real commit
    var isPending: Bool { isWIP || wipWorktree != nil }
    /// What selecting this graph row selects
    var rowSelection: Selection { isWIP ? .wip : wipWorktree.map { .worktree($0) } ?? .commit(id) }
}

struct CommitDetail: Hashable {
    let sha: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date
    let committer: String
    let committerEmail: String
    let commitDate: Date
    let summary: String
    let body: String
}

// MARK: - Refs

enum RefKind: Int, Hashable {
    case head, local, remote, tag
}

struct RefLabel: Identifiable, Hashable {
    let name: String
    let kind: RefKind
    let isCurrent: Bool
    var id: String { "\(kind.rawValue):\(name)" }
}

struct Branch: Identifiable, Hashable {
    /// 로컬은 "main", 원격은 "origin/main"
    let name: String
    let target: String
    let upstream: String?
    let ahead: Int
    let behind: Int
    let upstreamGone: Bool
    let isCurrent: Bool
    let isRemote: Bool

    var id: String { (isRemote ? "r:" : "l:") + name }

    /// 원격 브랜치의 리모트 이름(origin). 로컬이면 nil.
    var remote: String? {
        isRemote ? name.split(separator: "/", maxSplits: 1).first.map(String.init) : nil
    }

    /// 리모트 접두사를 뺀 이름(origin/feature/x → feature/x)
    var shortName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

struct Tag: Identifiable, Hashable {
    let name: String
    let target: String
    var id: String { name }
}

struct Stash: Identifiable, Hashable {
    let ref: String      // stash@{0}
    let hash: String
    let message: String
    var id: String { ref }
}

// MARK: - Working tree

enum ChangeKind: Hashable {
    case added, modified, deleted, renamed, copied, typeChanged, untracked, conflicted

    init(code: Character) {
        switch code {
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .conflicted
        default: self = .modified
        }
    }
}

struct FileChange: Identifiable, Hashable {
    let path: String
    let oldPath: String?
    let kind: ChangeKind
    let staged: Bool

    var id: String { (staged ? "s:" : "w:") + (oldPath.map { $0 + " → " } ?? "") + path }
    /// git 명령에 넘길 경로들(이름 변경이면 이전 경로 포함)
    var paths: [String] { [oldPath, path].compactMap { $0 } }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

struct WorkingStatus: Hashable {
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var staged: [FileChange] = []
    var unstaged: [FileChange] = []
    var conflicted: [FileChange] = []

    var isEmpty: Bool { staged.isEmpty && unstaged.isEmpty && conflicted.isEmpty }
    var count: Int { Set((staged + unstaged + conflicted).map(\.path)).count }

    /// Each file once (conflict, then working tree, then staged), as one list for another worktree
    var files: [FileChange] {
        var seen = Set<String>()
        return (conflicted + unstaged + staged).filter { seen.insert($0.path).inserted }
    }
}

enum RepoState: Hashable {
    case clean, merging, rebasing, cherryPicking, reverting

    var title: String {
        switch self {
        case .clean: return ""
        case .merging: return String(localized: "Merge in progress")
        case .rebasing: return String(localized: "Rebase in progress")
        case .cherryPicking: return String(localized: "Cherry-pick in progress")
        case .reverting: return String(localized: "Revert in progress")
        }
    }
}

/// 파일 하나의 추가·삭제 줄 수(바이너리면 nil)
struct LineStat: Hashable {
    let added: Int?
    let deleted: Int?
}

/// 로딩 화면에 보여 줄 제목과 지금 하는 일
struct LoadingInfo: Equatable {
    var title: String
    var step: String
}

struct Identity: Hashable {
    let name: String
    let email: String
}

enum SearchScope: String, CaseIterable, Identifiable {
    case commits, files, code
    var id: String { rawValue }
    var title: String {
        switch self {
        case .commits: return String(localized: "Commit")
        case .files: return String(localized: "File path")
        case .code: return String(localized: "Code changes")
        }
    }
    var prompt: String {
        switch self {
        case .commits: return String(localized: "Search messages, authors, SHAs, branches (⌘F)")
        case .files: return String(localized: "Find commits where a file's name or path changed")
        case .code: return String(localized: "Find commits that added or removed this code")
        }
    }
}

// MARK: - Selection / diff

enum Selection: Hashable {
    case wip
    /// Another worktree's row (its path)
    case worktree(String)
    case commit(String)
    case pullRequest(Int)
}

enum DiffSource: Hashable {
    case working(FileChange)
    case commit(sha: String, change: FileChange, parent: String?)
    /// PR·MR 에서 바뀐 파일(서버가 준 패치)
    case review(number: Int, change: FileChange, patch: String)
    /// Another worktree's uncommitted change, against its HEAD (read-only)
    case worktree(path: String, change: FileChange)

    var change: FileChange {
        switch self {
        case .working(let c): return c
        case .commit(_, let c, _): return c
        case .review(_, let c, _): return c
        case .worktree(_, let c): return c
        }
    }
}

struct DiffLine: Identifiable {
    enum Kind { case context, added, removed, hunk, meta }
    let id: Int
    let kind: Kind
    /// 화면용(탭을 공백으로 편 것)
    let text: String
    let oldNo: Int?
    let newNo: Int?
    /// 패치용 원문(앞의 +·-·공백 표시는 뺀 것)
    var raw: String = ""
    /// 몇 번째 덩어리(@@)에 속하는지
    var hunk: Int?
    /// 단어 단위로 바뀐 부분(text 의 글자 위치)
    var changes: [Range<Int>] = []
}

/// diff 의 덩어리 하나(@@ -oldStart,oldCount +newStart,newCount @@)
struct DiffHunk {
    /// lines 에서 @@ 줄의 위치
    let line: Int
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
}

struct DiffDocument {
    var lines: [DiffLine] = []
    var isBinary = false
    var truncated = false
    var error: String?
    /// 첫 @@ 앞의 원문 머리(diff --git·index·---·+++ …) — 줄 단위 스테이지용 패치에 쓴다
    var header: [String] = []
    var hunks: [DiffHunk] = []
    /// 머지 커밋의 결합 diff(@@@)
    var combined = false
    /// 여러 파일의 변경은 파일 하나의 줄 단위 패치로 만들 수 없다.
    var multipleFiles = false
    /// 나란히 보기의 줄들(왼쪽 이전 · 오른쪽 이후)
    var splitRows: [DiffSplitRow] = []
    /// 새 파일·지운 파일·이름·권한(diff 머리에서 읽은 것)
    var info = DiffFileInfo()
    /// 이전·이후 줄 번호가 하나라도 있는지(새 파일은 이전 칸, 지운 파일은 이후 칸이 없다)
    var hasOldSide = false
    var hasNewSide = false

    /// 한쪽만 있는 diff(새 파일·지운 파일·내용을 통째로 비운 파일): 나란히 봐도 한 칸으로 보인다
    var oneSided: Bool { !(hasOldSide && hasNewSide) }
}

/// diff 머리의 파일 정보
struct DiffFileInfo {
    var newFile = false
    var deletedFile = false
    var oldMode: String?
    var newMode: String?
    var renameFrom: String?
    var renameTo: String?
    /// 이름 바꾼 파일이 얼마나 같은지(%)
    var similarity: Int?

    var modeChanged: Bool { !newFile && !deletedFile && oldMode != nil && newMode != nil && oldMode != newMode }
    var renamed: Bool { renameFrom != nil && renameTo != nil }

    /// 권한 바뀜 설명(실행 권한이 생기거나 없어졌을 때)
    var modeSummary: String? {
        guard modeChanged, let o = oldMode, let n = newMode else { return nil }
        let exec = (o.hasSuffix("755"), n.hasSuffix("755"))
        let note = exec == (false, true) ? String(localized: " — now executable") : exec == (true, false) ? String(localized: " — no longer executable") : ""
        return "\(o) → \(n)\(note)"
    }
}

/// 나란히 보기 한 줄: @@·"줄바꿈 없음" 줄은 가로 전체(full), 그 밖에는 왼쪽(지운 줄·문맥)과 오른쪽(더한 줄·문맥). 값은 lines 의 위치.
struct DiffSplitRow: Identifiable {
    let id: Int
    var full: Int?
    var left: Int?
    var right: Int?
}

// MARK: - 파일 히스토리 · blame

/// 파일 히스토리 한 줄: 그 파일을 바꾼 커밋과, 그 커밋에서의 파일 경로(이름이 바뀌었을 수 있다)
struct FileHistoryEntry: Identifiable, Hashable {
    let commit: Commit
    let path: String
    var id: String { commit.id }
}

/// blame 한 줄: 그 줄을 마지막으로 바꾼 커밋
struct BlameLine: Identifiable {
    /// 줄 번호(1부터)
    let id: Int
    let sha: String
    let text: String
    let author: String
    let email: String
    let date: Date
    let summary: String
    /// 앞 줄과 다른 커밋이면 true(작성자·날짜는 이 줄에만 보여 준다)
    let startsBlock: Bool
    /// 아직 커밋하지 않은 줄
    var uncommitted: Bool { sha.allSatisfy { $0 == "0" } }
}

/// 가운데 영역에 띄우는 파일 보기
struct FileInspect: Equatable {
    enum Mode: Equatable { case history, blame }
    var mode: Mode
    let path: String
    /// blame 할 커밋(nil 이면 작업 트리)
    var rev: String?
}

// MARK: - Graph

struct GraphSegment: Hashable {
    /// x 는 레인 번호, y 는 행 높이 비율(0 위, 0.5 노드, 1 아래)
    let x1: Double
    let y1: Double
    let x2: Double
    let y2: Double
    let color: Int
    let dashed: Bool
}

struct GraphRow: Hashable {
    let column: Int
    let color: Int
    let segments: [GraphSegment]
    let width: Int
}

struct GraphEntry: Identifiable {
    let commit: Commit
    let row: GraphRow
    var id: String { commit.id }
}

// MARK: - Worktrees

struct Worktree: Identifiable, Hashable {
    let path: String
    let head: String?
    let branch: String?
    let isMain: Bool
    let locked: Bool
    let prunable: Bool
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct WorktreeStats: Hashable {
    var added = 0
    var modified = 0
    var deleted = 0
    var conflicted = 0
    var ahead = 0
    var behind = 0
    var hasUpstream = false

    init(_ s: WorkingStatus) {
        var kinds: [String: ChangeKind] = [:]
        for c in s.conflicted + s.staged + s.unstaged where kinds[c.path] == nil { kinds[c.path] = c.kind }
        for k in kinds.values {
            switch k {
            case .conflicted: conflicted += 1
            case .added, .untracked: added += 1
            case .deleted: deleted += 1
            default: modified += 1
            }
        }
        ahead = s.ahead
        behind = s.behind
        hasUpstream = s.upstream != nil
    }

    var isClean: Bool { added + modified + deleted + conflicted == 0 }
}

// MARK: - Hosting (GitHub / GitLab)

enum Provider: String, Codable, Hashable, CaseIterable, Identifiable {
    case github, gitlab
    var id: String { rawValue }
    var title: String { self == .github ? "GitHub" : "GitLab" }
    var requestName: String { self == .github ? "Pull Request" : "Merge Request" }
    var requestShort: String { self == .github ? "PR" : "MR" }
    var requestsTitle: String { self == .github ? "Pull Requests" : "Merge Requests" }
}

struct HostAccount: Codable, Hashable, Identifiable {
    let id: String
    let provider: Provider
    /// https://github.com, https://gitlab.회사.co.kr
    let server: String
    let username: String
    let name: String?
    let avatarURL: String?

    var host: String { URL(string: server)?.host?.lowercased() ?? server }
    var apiBase: String { provider == .github ? "https://api.github.com" : server + "/api/v4" }

    init(id: String, provider: Provider, server: String, username: String, name: String?, avatarURL: String?) {
        self.id = id
        self.provider = provider
        self.server = server
        self.username = username
        self.name = name
        self.avatarURL = avatarURL
    }

    private enum CodingKeys: String, CodingKey { case id, provider, server, username, name, avatarURL }

    /// 예전 버전(계정 하나, id·server 없음)으로 저장된 것도 읽는다
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(Provider.self, forKey: .provider)
        username = try c.decode(String.self, forKey: .username)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "legacy-\(provider.rawValue)"
        server = try c.decodeIfPresent(String.self, forKey: .server)
            ?? (provider == .github ? "https://github.com" : (UserDefaults.standard.string(forKey: "gitlabHost") ?? "https://gitlab.com"))
    }
}

/// 열린 저장소의 원격이 가리키는 호스팅 저장소
struct RepoTarget: Hashable {
    let provider: Provider
    let remote: String
    let host: String
    let path: String          // owner/repo, group/sub/repo
    var webURL: String { "https://\(host)/\(path)" }
}

extension RepoTarget {
    /// Where #123, !123 and @name in this repository's PR/MR text point
    var markdownRefs: Markdown.Refs {
        let web = webURL, host = host
        let user = { (name: String) in "https://\(host)/\(name)" }
        return provider == .github
            ? Markdown.Refs(issue: { "\(web)/issues/\($0)" }, user: user)
            : Markdown.Refs(issue: { "\(web)/-/issues/\($0)" }, request: { "\(web)/-/merge_requests/\($0)" }, user: user)
    }

    /// Images load only from the repository's own server, so a PR can't make the app contact any other host
    func canLoadImage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let h = url.host?.lowercased() else { return false }
        let own = host.lowercased().split(separator: ":").first.map(String.init) ?? host
        return h == own || (provider == .github && (h == "github.com" || h.hasSuffix(".githubusercontent.com")))
    }
}

struct PullRequest: Identifiable, Hashable {
    let number: Int
    let title: String
    let author: String
    let source: String
    let target: String
    let url: String
    let isDraft: Bool
    let updated: Date?
    let body: String
    let headSHA: String?
    let fromFork: Bool
    var id: Int { number }
}

struct RemoteRepo: Identifiable, Hashable {
    let fullName: String
    let cloneURL: String
    let isPrivate: Bool
    let summary: String?
    var id: String { fullName }
}

enum LoadState: Hashable {
    case idle, loading, loaded, needsAccount
    case failed(String)
}

// MARK: - UI requests

enum SheetKind: Identifiable {
    case clone
    case stash
    case newBranch(start: String, label: String)
    case tag(sha: String)
    case createPullRequest
    /// 에이전트 세션 시작(path 가 있으면 그 워크트리를 미리 고름)
    case startAgent(path: String?)
    /// branch 가 있으면 기존 브랜치를, 없으면 start 에서 새 브랜치를 워크트리로 체크아웃
    case addWorktree(branch: String?, start: String?)
    /// AI 가 나눈 커밋 계획 확인
    case splitCommits
    /// 새 파이프라인(GitLab) / 워크플로 실행(GitHub)
    case runPipeline
    /// 커밋 정리(인터랙티브 리베이스)
    case interactiveRebase
    /// 이 브랜치에서 바뀐 의존(gitch graph diff)의 기준 고르기
    case graphDiff
    /// 의존 규칙 검사 결과(gitch graph check)
    case graphCheck

    var id: String {
        switch self {
        case .clone: return "clone"
        case .stash: return "stash"
        case .newBranch(let s, _): return "branch:" + s
        case .tag(let s): return "tag:" + s
        case .createPullRequest: return "pr"
        case .startAgent(let p): return "agent:" + (p ?? "")
        case .addWorktree(let b, let s): return "wt:" + (b ?? "") + ":" + (s ?? "")
        case .splitCommits: return "split"
        case .runPipeline: return "runPipeline"
        case .interactiveRebase: return "interactiveRebase"
        case .graphDiff: return "graphDiff"
        case .graphCheck: return "graphCheck"
        }
    }
}

struct ConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let actionTitle: String
    var destructive = true
    let action: @MainActor () async -> Void
}

enum PullMode { case standard, fastForward, merge, rebase }

enum ResetMode: String { case soft, mixed, hard }

enum OpenResult {
    case opened
    case notRepository(URL)
    case failed(String)
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
