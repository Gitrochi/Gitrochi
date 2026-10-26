import Foundation

/// 인터랙티브 리베이스(커밋 정리)에서 커밋마다 할 일
enum RebaseAction: String, CaseIterable, Identifiable {
    case pick, reword, squash, fixup, drop
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pick: return String(localized: "Pick")
        case .reword: return String(localized: "Reword")
        case .squash: return String(localized: "Squash into the commit below")
        case .fixup: return String(localized: "Fixup into the commit below (discard message)")
        case .drop: return String(localized: "Drop")
        }
    }

    var symbol: String {
        switch self {
        case .pick: return "checkmark"
        case .reword: return "pencil"
        case .squash: return "arrow.down.to.line"
        case .fixup: return "arrow.down.to.line.compact"
        case .drop: return "trash"
        }
    }
}

struct RebaseItem: Identifiable, Hashable {
    let sha: String
    let subject: String
    /// 원래 전체 메시지
    let message: String
    let author: String
    var action: RebaseAction = .pick
    /// 메시지 고치기일 때 새 메시지
    var newMessage: String
    var id: String { sha }

    init(sha: String, message: String, author: String) {
        self.sha = sha
        self.message = message
        self.author = author
        subject = message.split(separator: "\n", maxSplits: 1).first.map { String($0).trimmed } ?? ""
        newMessage = message
    }
}

/// 커밋 정리 계획: base 위로 items 를 다시 쌓는다
struct RebasePlan {
    /// 이 커밋 위로 다시 쌓는다(nil 이면 첫 커밋부터 --root)
    var base: String?
    /// 화면 순서(위가 최신)
    var items: [RebaseItem]
    /// 원래 순서(위가 최신)
    let original: [String]
    /// 이미 원격에 올린 커밋이 들어 있는지
    var pushed = false
    /// 확인 화면 이후 HEAD가 바뀌었으면 실행하지 않는다.
    var expectedHead: String?

    init(base: String?, items: [RebaseItem], pushed: Bool = false) {
        self.base = base
        self.items = items
        original = items.map(\.sha)
        self.pushed = pushed
    }

    /// 실행할 수 없는 계획이면 그 이유
    var problem: String? {
        let kept = items.filter { $0.action != .drop }
        if kept.isEmpty { return String(localized: "Keep at least one commit.") }
        if let oldest = kept.last, oldest.action == .squash || oldest.action == .fixup {
            return String(localized: "The bottom (oldest) commit has nothing to combine into.")
        }
        if items.contains(where: { $0.action == .reword && $0.newMessage.trimmed.isEmpty }) { return String(localized: "The new message is empty.") }
        return nil
    }

    /// 원래와 달라진 게 있는지(순서·할 일·메시지)
    var changed: Bool {
        items.map(\.sha) != original || items.contains { $0.action != .pick && !($0.action == .reword && $0.newMessage == $0.message) }
    }

    /// git-rebase-todo 내용(오래된 것부터). 메시지 고치기는 그 커밋을 고른 뒤 새 메시지 파일로 고쳐 쓴다.
    func todo(messageFile: (String) -> String) -> String {
        var out: [String] = []
        for item in items.reversed() {
            switch item.action {
            case .pick: out.append("pick \(item.sha)")
            case .reword:
                out.append("pick \(item.sha)")
                if item.newMessage != item.message {
                    out.append("exec git commit --amend --allow-empty -F \(Self.shellQuote(messageFile(item.sha)))")
                }
            case .squash: out.append("squash \(item.sha)")
            case .fixup: out.append("fixup \(item.sha)")
            case .drop: out.append("drop \(item.sha)")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// sh 에 넘길 작은따옴표 인용
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
