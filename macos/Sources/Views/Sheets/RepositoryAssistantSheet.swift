import SwiftUI
import AppKit

struct RepositoryAssistantSheet: View {
    var embedded = false
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var state = store.repositoryAssistant
        let problem = AIStore.shared.problem(state.provider)
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
            Text("Repository assistant").font(.title3.bold())
            Text(state.providerTitle).font(.caption).foregroundStyle(.secondary)
            Text("Sending a question lets AI read tracked files, status and history in this repository. Each read is shown below. Files are never changed.").font(.caption).foregroundStyle(.secondary)
            Text(repositoryLabel(state))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            AssistantContextPanel()
            if state.loading { HStack { ProgressView().controlSize(.small); Text("Preparing repository context…") } }
            if !state.preview.isEmpty {
                DisclosureGroup("Context for AI") {
                    ScrollView { Text(state.preview.map { "\($0.tool)\n\($0.text)" + ($0.truncated ? "\n[truncated]" : "") }.joined(separator: "\n\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
                }
            }
            if !state.messages.isEmpty {
                ScrollView { VStack(alignment: .leading, spacing: 12) {
                    ForEach(state.messages) { message in VStack(alignment: .leading, spacing: 4) {
                        Text(message.user ? String(localized: "You") : String(localized: "AI answer")).font(.caption.bold()).foregroundStyle(.secondary)
                        Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if let context = message.context, context.fingerprint != store.captureWorkContext(scope: context.scope)?.fingerprint { Text("Answer belongs to an earlier selection.").font(.caption).foregroundStyle(.secondary) }
                        if let actions = message.graphActions {
                            Button("Apply graph selection") {
                                guard let data = try? JSONEncoder().encode(actions) else { return }
                                Task { await store.openAssistantGraph(actionsJSON: String(decoding: data, as: UTF8.self)) }
                            }.disabled(state.working || state.graphLoading || message.context?.fingerprint != store.captureWorkContext(scope: message.context?.scope)?.fingerprint)
                        }
                    } }
                }.padding(6) }.frame(maxHeight: 260)
            }
            if !state.traces.isEmpty {
                DisclosureGroup("Read activity") {
                    ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(state.traces) { trace in
                        DisclosureGroup(trace.name + " " + trace.arguments) { Text(trace.error ?? trace.result ?? String(localized: "Reading…")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    } } }.frame(maxHeight: 170)
                }
            }
            TextEditor(text: $state.question).font(.callout).frame(height: 80).padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))
                .accessibilityLabel(Text("Question about this repository"))
            Text("Reads are bounded and reflect the files at the time they are read. Secret paths, binary files and symlinks are excluded.").font(.caption).foregroundStyle(.secondary)
            if let error = state.error ?? problem { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: embedded ? .infinity : 560)
            HStack {
                Button("New conversation") { Task { await store.openRepositoryAssistant(fresh: true, present: !embedded) } }.disabled(state.loading || state.working)
                Spacer()
                if state.working { ProgressView().controlSize(.small); Button("Stop waiting") { state.stop() } }
                if !embedded { Button("Close") { dismiss() } }
                Button("Send question") { store.sendRepositoryQuestion() }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(state.loading || state.working || state.graphLoading || store.repositoryContextStale || state.reader == nil || state.question.trimmed.isEmpty || state.question.count > 6000 || problem != nil)
            }
        }.padding(20).frame(width: embedded ? nil : 860).frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil, alignment: .topLeading)
            .onDisappear { state.active = false; state.stop() }
    }

    private func repositoryLabel(_ state: RepositoryAssistantState) -> String {
        let path = state.repository?.path ?? ""
        let head = state.head.map { String($0.prefix(12)) } ?? String(localized: "No commits")
        return path + " · HEAD " + head
    }
}

struct MCPConnectionSheet: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var reader: RepositoryReader?
    @ViewState private var error: String?
    @ViewState private var notice = ""
    @ViewState private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect external AI with MCP").font(.title3.bold())
            Text("Copy this entry into your AI client's MCP settings. Only this repository is exposed, using read-only local tools.")
            Text("Requires Node.js 22 or later and Git. No server, account changes or network listener is created.").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(reader?.configuration ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 280)
            if !notice.isEmpty { Text(notice).font(.caption).textSelection(.enabled) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Test connection") { test() }.disabled(reader == nil || working)
                Spacer()
                Button("Close") { dismiss() }
                Button("Copy configuration") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(reader?.configuration ?? "", forType: .string)
                    notice = String(localized: "Copied")
                }.disabled(reader == nil)
            }
        }.padding(20).frame(width: 800)
            .task {
                guard let url = store.url else { return }
                do { reader = try await RepositoryReader.prepare(in: url) } catch { self.error = error.localizedDescription }
            }
    }

    private func test() {
        guard let reader else { return }
        working = true; error = nil
        Task {
            do { let result = try await reader.call("git_status"); notice = String(localized: "Read-only connection works.") + "\n" + result.text }
            catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
