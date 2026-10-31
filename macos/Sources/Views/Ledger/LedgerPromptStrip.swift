import SwiftUI

/// Agents waiting on a person right now, with the time left before auto-continue answers: in full at the top of the
/// Inbox, one line each above the other views. Its buttons are reached with Tab; no single key answers an agent.
/// (Windows: widgets/ledger-workspace/ui/LedgerPromptStrip.tsx)
struct LedgerPromptStrip: View {
    let prompts: [LedgerPendingPrompt]
    let ledger: LedgerStore
    var compact = false
    /// Shows the Inbox, where a question is answered in full
    var openInbox: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            LedgerSectionHeader(title: String(localized: "Waiting now"), count: prompts.count)
            ForEach(prompts) { prompt in
                if compact {
                    LedgerPromptLine(prompt: prompt, ledger: ledger, openInbox: openInbox)
                } else {
                    LedgerPromptCard(prompt: prompt, ledger: ledger)
                }
            }
        }
    }
}

/// One waiting prompt in a line: what it is, the time left, and the answers that need no typing
private struct LedgerPromptLine: View {
    let prompt: LedgerPendingPrompt
    let ledger: LedgerStore
    let openInbox: () -> Void

    private var busy: Bool { ledger.working.contains("p\(prompt.id)") }

    var body: some View {
        let session = ledger.session(prompt.sessionId)
        HStack(spacing: 8) {
            Image(systemName: prompt.kind.symbol).foregroundStyle(Color(nsColor: .systemOrange)).accessibilityHidden(true)
            if let session { LedgerSessionLabel(id: session.id, color: session.color) }
            Text(summary).font(.callout).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            Spacer(minLength: 6)
            LedgerCountdownView(prompt: prompt, skew: ledger.clockSkew, inline: true)
            Group {
                switch prompt.kind {
                case .permission, .exitPlanMode:
                    Button("Allow") { Task { await ledger.reply(prompt, .allow) } }
                    Button("Deny") { Task { await ledger.reply(prompt, .deny(message: nil)) } }
                case .stopQuestion, .askUserQuestion:
                    Button("Answer…", action: openInbox).help("Answer in the Inbox")
                }
                Button("Answer in terminal") { Task { await ledger.reply(prompt, .answerInTerminal) } }
                    .help("Stop waiting here and let the agent ask in its own terminal")
            }
            .disabled(busy)
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .systemOrange).opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .systemOrange).opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prompt.kind.title + ": " + summary)
    }

    private var summary: String {
        switch prompt.kind {
        case .stopQuestion: return prompt.payload["question"]?.string ?? prompt.payload["message"]?.string ?? prompt.kind.title
        case .askUserQuestion: return prompt.payload["questions"]?.array.first?["question"].string ?? prompt.kind.title
        case .exitPlanMode: return prompt.kind.title
        case .permission:
            let input = prompt.payload["input"] ?? .null
            return (prompt.payload["toolName"]?.string ?? "") + ": " + (input["command"].string ?? prompt.payload["description"]?.string ?? "")
        }
    }
}

extension LedgerPendingPrompt.Kind {
    var title: String {
        switch self {
        case .stopQuestion: return String(localized: "Asks a question")
        case .askUserQuestion: return String(localized: "Asks you to choose")
        case .exitPlanMode: return String(localized: "Plan to approve")
        case .permission: return String(localized: "Asks for permission")
        }
    }

    var symbol: String {
        switch self {
        case .stopQuestion: return "questionmark.bubble"
        case .askUserQuestion: return "list.bullet.circle"
        case .exitPlanMode: return "list.clipboard"
        case .permission: return "lock.shield"
        }
    }
}

private struct LedgerPromptCard: View {
    let prompt: LedgerPendingPrompt
    let ledger: LedgerStore
    @ViewState private var text = ""
    @ViewState private var chosen: [String: Set<String>] = [:]
    @ViewState private var showWholePlan = false

    private var busy: Bool { ledger.working.contains("p\(prompt.id)") }
    private var session: LedgerSession? { ledger.session(prompt.sessionId) }
    private var questions: [LedgerJSON] { prompt.payload["questions"]?.array ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .systemOrange).opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .systemOrange).opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prompt.kind.title + (session.map { ", " + $0.id + " " + $0.title } ?? ""))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: prompt.kind.symbol).font(.system(size: 15)).foregroundStyle(Color(nsColor: .systemOrange))
                .frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.kind.title).font(.callout.weight(.semibold))
                if let session {
                    HStack(spacing: 6) {
                        LedgerSessionLabel(id: session.id, color: session.color)
                        Text(session.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                } else if let agent = prompt.agentId {
                    Text(agent).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            LedgerCountdownView(prompt: prompt, skew: ledger.clockSkew)
        }
    }

    @ViewBuilder private var content: some View {
        switch prompt.kind {
        case .stopQuestion:
            Text(prompt.payload["question"]?.string ?? prompt.payload["message"]?.string ?? "")
                .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            LedgerAnswerField(placeholder: String(localized: "Your answer…"), text: $text, saveTitle: String(localized: "Answer"), busy: busy) {
                Task { await ledger.reply(prompt, .text(text.trimmingCharacters(in: .whitespacesAndNewlines))) }
            }
        case .askUserQuestion:
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in choice(q) }
        case .exitPlanMode:
            let plan = prompt.payload["plan"]?.string ?? ""
            VStack(alignment: .leading, spacing: 4) {
                MarkdownView(plan)
                    .frame(maxHeight: showWholePlan ? nil : 110, alignment: .top)
                    .clipped()
                if plan.split(separator: "\n").count > 6 {
                    Button(showWholePlan ? String(localized: "Show less") : String(localized: "Show the whole plan")) { showWholePlan.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        case .permission:
            let tool = prompt.payload["toolName"]?.string ?? ""
            let input = prompt.payload["input"] ?? .null
            VStack(alignment: .leading, spacing: 4) {
                if let description = prompt.payload["description"]?.string { Text(description).font(.callout) }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(tool).font(.caption.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                    Text(input["command"].string ?? Self.describe(input))
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(4).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func choice(_ q: LedgerJSON) -> some View {
        let question = q["question"].string ?? ""
        let multiple = q["multiSelect"].bool ?? false
        let picked = chosen[question] ?? []
        return VStack(alignment: .leading, spacing: 5) {
            if let header = q["header"].string { Text(header.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary) }
            Text(question).font(.callout).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(q["options"].array.enumerated()), id: \.offset) { _, option in
                let label = option["label"].string ?? ""
                Button {
                    var next = multiple ? picked : []
                    if next.contains(label) { next.remove(label) } else { next.insert(label) }
                    chosen[question] = next
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: picked.contains(label) ? (multiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                                                                 : (multiple ? "square" : "circle"))
                            .foregroundStyle(picked.contains(label) ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(label).font(.callout)
                            if let detail = option["description"].string { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityAddTraits(picked.contains(label) ? .isSelected : [])
            }
        }
    }

    private var canAnswerChoices: Bool {
        !questions.isEmpty && questions.allSatisfy { !(chosen[$0["question"].string ?? ""] ?? []).isEmpty }
    }

    private var actions: some View {
        WorkbenchFlow(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            switch prompt.kind {
            case .askUserQuestion:
                Button("Answer") {
                    var answers: [String: String] = [:]
                    for q in questions {
                        let question = q["question"].string ?? ""
                        let order = q["options"].array.compactMap { $0["label"].string }
                        answers[question] = order.filter { (chosen[question] ?? []).contains($0) }.joined(separator: ", ")
                    }
                    Task { await ledger.reply(prompt, .choices(answers)) }
                }
                .buttonStyle(.borderedProminent).disabled(busy || !canAnswerChoices)
            case .permission, .exitPlanMode:
                Button("Allow") { Task { await ledger.reply(prompt, .allow) } }.buttonStyle(.borderedProminent).disabled(busy)
                Button("Deny") { Task { await ledger.reply(prompt, .deny(message: nil)) } }.disabled(busy)
            case .stopQuestion:
                EmptyView()
            }
            Button("Answer in terminal") { Task { await ledger.reply(prompt, .answerInTerminal) } }
                .disabled(busy)
                .help("Stop waiting here and let the agent ask in its own terminal")
            if LedgerCountdown.isCounting(prompt) {
                Button("Turn off auto this time") { Task { await ledger.reply(prompt, .holdAuto) } }
                    .disabled(busy)
                    .help("Keep this prompt waiting for you instead of answering it automatically")
            }
            if LedgerCountdown.isCounting(prompt), let auto = prompt.payload["autoReply"]?.string {
                Text("If nobody answers: “\(auto)”").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .controlSize(.small)
    }

    private static func describe(_ input: LedgerJSON) -> String {
        guard let object = input.object else { return "" }
        return object.keys.sorted().map { key in key + ": " + (object[key]?.string ?? "…") }.joined(separator: "  ")
    }
}

/// The time left until auto-continue answers, ticking every second; a held prompt says it waits for a person
struct LedgerCountdownView: View {
    let prompt: LedgerPendingPrompt
    let skew: LedgerMs
    /// Without the bar, for one-line prompts
    var inline = false

    var body: some View {
        if LedgerCountdown.isCounting(prompt) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = LedgerMs((context.date.timeIntervalSince1970 * 1000).rounded()) + skew
                VStack(alignment: .trailing, spacing: 4) {
                    Label("Auto in \(LedgerCountdown.text(deadline: prompt.deadline, now: now))", systemImage: "timer")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize()
                    if !inline {
                        ProgressView(value: LedgerCountdown.fraction(created: prompt.createdAt, deadline: prompt.deadline, now: now))
                            .progressViewStyle(.linear).tint(Color(nsColor: .systemOrange)).frame(width: 96)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Auto-continues in \(LedgerCountdown.spoken(deadline: prompt.deadline, now: now))"))
            }
        } else {
            Label("Waiting for you", systemImage: "hand.raised").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}
