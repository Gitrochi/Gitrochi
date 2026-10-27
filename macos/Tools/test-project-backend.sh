#!/usr/bin/env bash
# Production local/cloud routing with memory-only persistence and HTTP that must never run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Tools/project-backend-test-sources.sh"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

enum Provider: String { case github, gitlab }
struct RepoTarget { var provider: Provider; var remote: String; var host: String; var path: String }
struct HostingError: LocalizedError { let status: Int; var errorDescription: String? { "HTTP \(status)" } }
enum Hosting {
    static var calls = 0
    static func projectID(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
    static func request(_ provider: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest { calls += 1; fatalError("Local projects reached authenticated HTTP") }
    static func data(_ request: URLRequest) async throws -> Data { fatalError("Local projects reached HTTP") }
}
actor MemoryPersistence: LocalProjectPersistence {
    var content: String?
    var writes = 0
    func read() -> String? { content }
    func write(expected: String?, content: String) throws { guard expected == self.content else { throw LocalProjectError.stale }; self.content = content; writes += 1 }
}
@main struct ProjectBackendTests {
    @MainActor static func main() async throws {
        let memory = MemoryPersistence(), store = LocalProjectStore(storage: memory)
        HostingHubAPI.localProjectStore = store
        let access = HubAccess(target: RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "reader/workspace"), token: "", apiBase: "https://api.github.com", me: "", local: true)
        let created = try await store.create(title: "Local plan", description: "Private device notes")
        let page = try await HostingHubAPI.page(access, section: .projects)
        precondition(page.items.map(\.id) == [created.id] && page.items[0].url.isEmpty)
        var detail = try await HostingHubAPI.detail(access, section: .projects, item: created)
        try await HostingHubAPI.saveProjectSettings(access, detail: detail, input: HubProjectSettingsInput(title: "Renamed local plan", shortDescription: "Local summary", readme: "Ignored cloud readme", isPublic: true, closed: true))
        detail = try await HostingHubAPI.detail(access, section: .projects, item: created)
        precondition(detail.item.title == "Renamed local plan" && detail.item.body == "Local summary" && detail.item.data["public"] == nil && detail.item.url.isEmpty)
        try await HostingHubAPI.saveProjectDraft(access, detail: detail, title: "First", body: "Body")
        detail = try await HostingHubAPI.detail(access, section: .projects, item: created)
        let first = detail.rows[0]
        try await HostingHubAPI.saveProjectDraft(access, detail: detail, title: "Second", body: "")
        detail = try await HostingHubAPI.detail(access, section: .projects, item: created)
        let second = detail.rows[1]
        try await HostingHubAPI.moveProjectItem(access, detail: detail, row: second, afterRow: nil)
        detail = try await HostingHubAPI.detail(access, section: .projects, item: created)
        precondition(detail.rows.map(\.id) == [second.id, first.id])
        try await HostingHubAPI.updateProjectField(access, detail: detail, row: first, field: detail.fields.first { $0.id == "local-priority" }!, value: "local-high")
        detail = try await HostingHubAPI.detail(access, section: .projects, item: created)
        precondition(detail.rows.first { $0.id == first.id }!.values["local-priority"] == "local-high")
        try await HostingHubAPI.updateProjectField(access, detail: detail, row: first, field: detail.fields.first { $0.id == "local-start" }!, value: "2026-10-01")
        detail = try await HostingHubAPI.detail(access, section: .projects, item: created)
        try await HostingHubAPI.updateProjectField(access, detail: detail, row: first, field: detail.fields.first { $0.id == "local-due" }!, value: "2026-10-04")
        detail = try await HostingHubAPI.detail(access, section: .projects, item: created)
        let beforeSchedule = await memory.writes
        try await HostingHubAPI.rescheduleProjectItem(access, detail: detail, row: first, settings: .init(), targetDay: "2026-10-10")
        detail = try await HostingHubAPI.detail(access, section: .projects, item: created)
        let scheduled = detail.rows.first { $0.id == first.id }!, afterSchedule = await memory.writes
        precondition(scheduled.values["local-start"] == "2026-10-07" && scheduled.values["local-due"] == "2026-10-10" && afterSchedule == beforeSchedule + 1)
        try await HostingHubAPI.archiveProjectItem(access, detail: detail, row: second, archived: true)
        detail = try await HostingHubAPI.detail(access, section: .projects, item: created)
        precondition(detail.rows.first { $0.id == second.id }!.archived)
        try await HostingHubAPI.archiveProjectItem(access, detail: detail, row: second, archived: false)
        detail = try await HostingHubAPI.detail(access, section: .projects, item: created)
        try await HostingHubAPI.deleteProjectItem(access, detail: detail, row: second)
        detail = try await HostingHubAPI.detail(access, section: .projects, item: created)
        precondition(detail.rows.map(\.id) == [first.id])
        let beforeInvalid = await memory.writes
        var remote = access; remote.local = false
        do { try await HostingHubAPI.saveProjectDraft(remote, detail: detail, title: "Wrong backend", body: ""); fatalError("Local task sent to cloud") } catch {}
        do { try await HostingHubAPI.saveProjectSettings(remote, detail: detail, input: HubProjectSettingsInput(title: "Wrong", shortDescription: "", readme: "", isPublic: true, closed: false)); fatalError("Local settings sent to cloud") } catch {}
        do { _ = try await HostingHubAPI.projectViews(remote, detail: detail); fatalError("Local view ID sent to cloud") } catch {}
        do { try await HostingHubAPI.convertProjectDraftToIssue(access, detail: detail, row: first, repository: "team/repo"); fatalError("Local task published implicitly") } catch {}
        do { _ = try await HostingHubAPI.inspectProjectCreationCapabilities(access); fatalError("Local task probed account") } catch {}
        do { _ = try await HostingHubAPI.createProject(access, title: "Cloud"); fatalError("Local task created cloud project") } catch {}
        var remoteDetail = detail; remoteDetail.item.id = "REMOTE"
        do { try await HostingHubAPI.saveProjectDraft(access, detail: remoteDetail, title: "Wrong backend", body: ""); fatalError("Remote task sent to local store") } catch {}
        var stale = access; stale.isCurrent = { false }
        do { try await HostingHubAPI.saveProjectDraft(stale, detail: detail, title: "Stale", body: ""); fatalError("Stale task saved") } catch {}
        let writesAfterInvalid = await memory.writes
        precondition(writesAfterInvalid == beforeInvalid && Hosting.calls == 0)
        print("Project backend: local CRUD, settings, order, atomic schedules, field values, archive and source/context isolation passed without HTTP, accounts or disk writes")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/HostingHub.swift" "${PROJECT_BACKEND_TEST_SOURCES[@]}" "$ROOT/Sources/Services/ProjectManagement.swift" "$ROOT/Sources/Services/ProjectScheduling.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-project-backend"
"$TASK_TMP/test-project-backend"
