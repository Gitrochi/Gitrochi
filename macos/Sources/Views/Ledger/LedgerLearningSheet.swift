import SwiftUI

/// Replayable local practice and a searchable reference; opening it never starts an agent.
@MainActor struct LedgerLearningSheet: View {
    enum Tab { case tutorial, guide }
    @ViewState private var learning: LedgerLearning
    @ViewState private var tab: Tab
    @ViewState private var query = ""
    @ViewState private var expanded: Set<String> = ["setup"]
    @Environment(\.dismiss) private var dismiss
    var openConnect: (() -> Void)?
    var bringChatGPTDraft: (() -> Void)?
    var openBrowser: (() -> Void)?

    init(learning: LedgerLearning? = nil, initialTab: Tab = .tutorial,
         openConnect: (() -> Void)? = nil, bringChatGPTDraft: (() -> Void)? = nil, openBrowser: (() -> Void)? = nil) {
        _learning = ViewState(wrappedValue: learning ?? LedgerLearning())
        _tab = ViewState(wrappedValue: initialTab)
        self.openConnect = openConnect
        self.bringChatGPTDraft = bringChatGPTDraft
        self.openBrowser = openBrowser
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Learn Ledger").font(.title3.weight(.semibold))
                Spacer(minLength: 4)
                if learning.progress.completed {
                    Label("Completed", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).help("Close").accessibilityLabel("Close")
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            HStack(spacing: 20) {
                tabButton(.tutorial, title: String(localized: "Tutorial"))
                tabButton(.guide, title: String(localized: "Guide"))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            Divider()
            if tab == .tutorial {
                tutorial
                Divider()
                navigation
            } else {
                guide
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 500, idealWidth: 720, maxWidth: 840, minHeight: 560, idealHeight: 720, maxHeight: 900)
    }

    private func tabButton(_ value: Tab, title: String) -> some View {
        let selected = tab == value
        return Button { tab = value } label: {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.primary : .secondary)
                .frame(height: 36)
                .overlay(alignment: .bottom) {
                    if selected { Rectangle().fill(Color.accentColor).frame(height: 2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var tutorial: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Step \(learning.progress.step + 1) of \(LedgerLearning.Step.allCases.count)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ProgressView(value: Double(learning.progress.step + 1), total: Double(LedgerLearning.Step.allCases.count))
                    .accessibilityLabel("Tutorial")
                Text(learning.step.title).font(.system(size: 17, weight: .semibold))
                Text(learning.step.body).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                practice
                Text("This practice stays local and does not change your Ledger.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var practice: some View {
        switch learning.step {
        case .concepts:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Baseline", systemImage: "tag").font(.system(size: 12, weight: .medium))
                    Text("v1.0.0").font(.system(size: 13))
                }
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Session", systemImage: "bubble.left.and.bubble.right").font(.system(size: 12, weight: .medium))
                    Text("S1").font(.system(size: 13))
                }
                Spacer(minLength: 0)
            }
            .padding(16).background(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioStyle.border))
        case .views:
            HStack(spacing: 8) {
                ForEach(Array(LedgerPage.allCases.enumerated()), id: \.offset) { index, page in
                    Button { learning.chosenView = index } label: {
                        Label(page.title, systemImage: page.symbol).font(.system(size: 12))
                            .padding(8).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 6).fill(learning.chosenView == index ? StudioStyle.selection : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(learning.chosenView == index ? .isSelected : [])
                }
            }
        case .answer:
            LedgerQuestionAnswerEditor(question: LedgerLearning.question,
                                       text: Binding(get: { learning.answerDraft }, set: { learning.answerDraft = $0 }),
                                       submit: { learning.sendPracticeAnswer() })
            HStack(spacing: 10) {
                Button("Send answer") { learning.sendPracticeAnswer() }
                    .prominentButton(!learning.progress.answerSent)
                    .disabled(learning.answerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if learning.progress.answerSent {
                    Label("Saved", systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text("Return adds a line · ⌘Return saves").font(.system(size: 11)).foregroundStyle(.secondary)
            if !learning.progress.answerSent {
                Text("Answer every question before sending.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .delivery:
            VStack(alignment: .leading, spacing: 12) {
                Text(learning.progress.deliveryState.caption).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                switch learning.progress.deliveryState {
                case .saved: Button("Mark delivered") { learning.deliver() }.buttonStyle(.borderedProminent)
                case .delivered: Button("Confirm") { learning.confirm() }.buttonStyle(.borderedProminent)
                case .confirmed: Button("Clean up") { learning.archive() }.buttonStyle(.borderedProminent)
                case .archived: Label("Archived", systemImage: "archivebox").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioStyle.border))
        case .connect:
            setupActions
        }
    }

    private var navigation: some View {
        HStack(spacing: 10) {
            Button("Back") { learning.back() }.disabled(learning.progress.step == 0)
            Button("Restart") { learning.restart() }
            Spacer(minLength: 4)
            Button(learning.step == .connect ? String(localized: "Done") : String(localized: "Next")) {
                let last = learning.step == .connect
                learning.next()
                if last { dismiss() }
            }
            .buttonStyle(.borderedProminent).disabled(!learning.canAdvance)
        }
        .controlSize(.regular).padding(16)
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search the guide", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search the guide")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let topics = LedgerGuideTopic.matching(query)
                    if topics.isEmpty {
                        Text("No guide topics match.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    ForEach(topics) { topic in
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(topic.id) }, set: { value in
                                if value { expanded.insert(topic.id) } else { expanded.remove(topic.id) }
                            })) {
                                guideContent(topic).padding(.top, 8)
                            } label: { Text(topic.title).font(.system(size: 13, weight: .semibold)) }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(topic.title).font(.system(size: 13, weight: .semibold))
                                guideContent(topic)
                            }
                        }
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
    }

    private func guideContent(_ topic: LedgerGuideTopic) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(topic.body).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let detail = topic.detail {
                Text(detail).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if topic == .setup { setupActions }
            if topic == .shortcuts {
                Text("Return adds a line · ⌘Return saves").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var setupActions: some View {
        WorkbenchFlow(spacing: 10) {
            if let openConnect { Button("Connect agents…", action: openConnect) }
            if let openBrowser { Button("ChatGPT browser extension", action: openBrowser) }
            if let bringChatGPTDraft { Button("Bring a ChatGPT draft…", action: bringChatGPTDraft) }
        }
    }
}
