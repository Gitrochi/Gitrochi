import SwiftUI

struct RepositoryLanguageControl: View {
    let segments: [RepositoryLanguages.Segment]
    var truncated = false
    @Binding var selected: String?
    @ViewState private var showing = false

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Button { showing.toggle() } label: {
                    HStack(spacing: 5) {
                        Text("Languages").font(.caption.weight(.medium))
                        if let selected { Text(LocalizedStringKey(selected)).font(.caption).foregroundStyle(Color.accentColor).lineLimit(1) }
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                }.buttonStyle(.plain).help("Language composition").accessibilityIdentifier("code-language-composition")
                    .popover(isPresented: $showing) { RepositoryLanguageSummary(segments: segments, truncated: truncated, selected: $selected).frame(width: 280) }
                Spacer(minLength: 0)
                if selected != nil { Button { selected = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help("All languages").accessibilityLabel("All languages") }
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(segments) { segment in RepositoryLanguageSummary.color(segment.language).frame(width: geometry.size.width * segment.fraction) }
                }.clipShape(Capsule())
            }.frame(height: 5).accessibilityHidden(true)
        }.padding(.horizontal, 12).padding(.vertical, 9).onChange(of: selected) { _, _ in showing = false }
    }
}

struct RepositoryLanguageSummary: View {
    let segments: [RepositoryLanguages.Segment]
    var truncated = false
    @Binding var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Languages").font(.caption.weight(.semibold))
                Spacer()
                Text("By file count").font(.caption2).foregroundStyle(.secondary)
            }
            if segments.isEmpty { Text("No language data").font(.caption).foregroundStyle(.secondary) }
            else {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(segments) { segment in
                            color(segment.language).frame(width: geometry.size.width * segment.fraction)
                                .help(summary(segment))
                        }
                    }.clipShape(Capsule())
                }.frame(height: 7).accessibilityLabel("Language composition")
                ForEach(Array(segments.prefix(6))) { segment in legend(segment) }
                if segments.count > 6 {
                    DisclosureGroup {
                        VStack(spacing: 8) { ForEach(Array(segments.dropFirst(6))) { segment in legend(segment) } }.padding(.top, 6)
                    } label: { Text("Languages").font(.caption); Text("+\(segments.count - 6)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                if selected != nil {
                    Button("All languages") { selected = nil }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("code-all-languages")
                }
            }
            if truncated { Text("File list truncated. Narrow the repository or use another tool for the remaining files.").font(.caption).foregroundStyle(.secondary) }
        }.padding(12).background(Color(nsColor: .textBackgroundColor).opacity(0.55))
    }

    private func legend(_ segment: RepositoryLanguages.Segment) -> some View {
        Button { selected = selected == segment.language ? nil : segment.language } label: {
            HStack(spacing: 6) {
                Circle().fill(color(segment.language)).frame(width: 7, height: 7)
                Text(LocalizedStringKey(segment.language)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(segment.fraction.formatted(.percent.precision(.fractionLength(1)))).monospacedDigit().foregroundStyle(.secondary)
                Text(String(segment.count)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 15, alignment: .trailing)
            }.font(.caption).padding(.vertical, 2).contentShape(Rectangle())
                .foregroundStyle(selected == segment.language ? Color.accentColor : .primary)
        }.buttonStyle(.plain).help(summary(segment)).accessibilityLabel(summary(segment))
            .accessibilityAddTraits(selected == segment.language ? .isSelected : []).accessibilityIdentifier("code-language-" + segment.language)
    }

    private func summary(_ segment: RepositoryLanguages.Segment) -> String {
        String(localized: String.LocalizationValue(segment.language)) + " · " + String(localized: "{0} files").replacingOccurrences(of: "{0}", with: segment.count.formatted()) + " · " + segment.fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    static func color(_ language: String) -> Color {
        switch language {
        case "Swift", "HTML", "Rust": return .orange
        case "TypeScript", "CSS", "C", "C++", "C#": return .blue
        case "JavaScript", "JSON", "YAML": return .yellow
        case "Python", "Go", "Java": return .teal
        case "Markdown", "Plain text", "Configuration": return .secondary
        case "Shell", "Vue", "Svelte": return .green
        case "Other files": return Color(nsColor: .tertiaryLabelColor)
        default: return .purple
        }
    }
    private func color(_ language: String) -> Color { Self.color(language) }
}
