import SwiftUI
import AppKit

/// 버전과 자동 업데이트
struct UpdateSettings: View {
    private let center = UpdateCenter.shared

    var body: some View {
        @Bindable var center = center
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text("Gitrochi \(UpdateCenter.currentVersion)").font(.headline)
                        Text("An app for viewing and working with Git repositories as a graph · MIT").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("Release notes", destination: URL(string: "https://github.com/\(UpdateCenter.repo)/releases")!)
                }
            }
            Section("Automatic updates") {
                Toggle("Check for new versions at launch and once a day", isOn: $center.autoCheck)
                HStack {
                    Button("Check now") { Task { await center.check(manual: true) } }
                        .disabled(center.phase == .checking || center.phase == .downloading)
                    if center.phase == .checking { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Text("Tells you when a new version is available; click to download, replace and restart. A downloaded file is installed only if its SHA-256 and signature match the release.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            BackgroundSettings()
        }
        .formStyle(.grouped)
    }

    private var status: String {
        switch center.phase {
        case .checking: return String(localized: "Checking…")
        case .available: return String(localized: "Version \(center.latest?.version ?? "") is available")
        case .upToDate: return String(localized: "You're up to date")
        case .failed(let m): return String(localized: "Check failed: \(m)")
        default: return ""
        }
    }
}
