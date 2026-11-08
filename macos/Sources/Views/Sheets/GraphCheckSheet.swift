import SwiftUI
import AppKit

/// 의존 규칙 검사(gitch graph check) 결과: 어긴 규칙과 그 연결 · 순환. 「View as graph」는 같은 검사를 html 로 그려 기본 브라우저로 연다.
struct GraphCheckSheet: View {
    @Environment(RepoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// 그래프 페이지를 만들지 못한 까닭(gitch 문구)
    @ViewState private var pageError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dependency rules").font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            .padding([.top, .horizontal], 20)
            .padding(.bottom, 12)
            content
                .padding(.horizontal, 20)
            if let pageError {
                Text(pageError)
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20).padding(.top, 8)
            }
            HStack {
                Button("Edit rules") { Task { await store.openGraphRules() } }
                Button("Check again") {
                    pageError = nil
                    Task { await store.runGraphCheck() }
                }
                .disabled(running)
                Spacer()
                if store.graphJob == .checkPage { ProgressView().controlSize(.small) }
                Button("View as graph") {
                    pageError = nil
                    Task { pageError = await store.openGraphCheckPage() }
                }
                .disabled(!canShowGraph)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 620)
        .onExitCommand { dismiss() }
        // 검사가 돌고 있으면 두고 간다 — 바로 다시 열면 새로 돌리지 않고 그 결과를 기다린다(겹쳐 돌면 늦게 끝난 쪽이 덮는다)
        .onDisappear { if case .running? = store.graphCheck {} else { store.graphCheck = nil } }
    }

    @ViewBuilder private var content: some View {
        switch store.graphCheck {
        case .running?, nil:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking dependency rules…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .failed(let message)?:
            Card(spacing: 6) {
                Label("Couldn't check the rules", symbol: "xmark.octagon.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        case .done(let result, let rules)?:
            if rules == 0 {
                // --init 이 만든 예시는 모두 주석 — 위반 없음이 아니라 아직 검사할 규칙이 없다
                Card {
                    Label("No rules yet. Remove the # in front of the examples and adjust them to this repository, then check again.", symbol: "info.circle")
                }
            } else if result.violations.isEmpty {
                Card {
                    Label("No violations", symbol: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
            } else {
                violations(result.violations)
            }
        }
    }

    private func violations(_ list: [Gitch.GraphCheck.Violation]) -> some View {
        // 위반(실패로 세는 것) 먼저, 같은 무게면 규칙 파일의 줄 순서로
        let sorted = list.sorted { ($0.isError ? 0 : 1, $0.line) < ($1.isError ? 0 : 1, $1.line) }
        let errors = sorted.filter(\.isError).count
        let warnings = sorted.count - errors
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                if errors > 0 {
                    Label("Violations \(errors)", symbol: "xmark.octagon.fill").foregroundStyle(.red)
                } else {
                    Label("No violations", symbol: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if warnings > 0 {
                    Label("Warnings \(warnings)", symbol: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(sorted.enumerated()), id: \.offset) { _, v in row(v) }
                }
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            if warnings > 0 {
                Text("Warnings are links guessed only from names, so they don't count as violations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ v: Gitch.GraphCheck.Violation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SymbolIcon(v.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(v.isError ? Color.red : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // 규칙 파일에 쓴 줄 그대로(빈칸만 하나로)
                    Text(v.rule.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                    Text(verbatim: "[\(v.relation)] · " + String(localized: "Line \(v.line)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(link(v))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .accessibilityElement(children: .combine)
    }

    /// 어긴 연결(원본 → 대상), 순환이면 이루는 노드를 · 로
    private func link(_ v: Gitch.GraphCheck.Violation) -> String {
        if let nodes = v.nodes, !nodes.isEmpty { return nodes.joined(separator: " · ") }
        return "\(v.source ?? "?") → \(v.target ?? "?")"
    }

    private var subtitle: String {
        if case .done(let result, let rules)? = store.graphCheck {
            return result.file + " · " + String(localized: "Rules \(rules)")
        }
        return ".gitch/graph.rules"
    }

    private var running: Bool {
        if case .done? = store.graphCheck { return false }
        if case .failed? = store.graphCheck { return false }
        return true
    }

    /// 규칙이 하나도 없으면 gitch 가 빈 페이지를 만들어서 끈다
    private var canShowGraph: Bool {
        guard store.graphJob == nil, case .done(_, let rules)? = store.graphCheck else { return false }
        return rules > 0
    }
}
