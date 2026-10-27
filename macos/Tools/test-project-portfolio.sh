#!/usr/bin/env bash
# Exercise isolated portfolio reads and aggregation without credentials, preferences or network access.
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
    static func projectID(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
    static func request(_ provider: Provider, _ url: String, token: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest { fatalError("Unexpected credential or network request") }
    static func data(_ request: URLRequest) async throws -> Data { fatalError("Unexpected network request") }
}
@MainActor final class ReadGate<Value> {
    var continuation: CheckedContinuation<Value, Never>?
    func wait() async -> Value { await withCheckedContinuation { continuation = $0 } }
    func finish(_ value: Value) { continuation!.resume(returning: value); continuation = nil }
}
final class MemoryDefaults: UserDefaults {
    var values: [String: Data] = [:]
    override func data(forKey key: String) -> Data? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value as? Data }
}

@main struct ProjectPortfolioTests {
    @MainActor static func main() async throws {
        func item(_ id: String) -> HubItem { HubItem(id: id, title: "Project " + id) }
        func row(_ id: String, _ due: String = "", contentID: String? = nil, url: String = "", kind: HubProjectRowKind = .issue, archived: Bool = false) -> HubProjectRow {
            HubProjectRow(id: id, title: id, body: "", url: url, contentID: contentID ?? id, statuses: [:], kind: kind, archived: archived, values: due.isEmpty ? [:] : ["due": due])
        }
        func detail(_ id: String, _ rows: [HubProjectRow] = [], more: Bool = false, cursor: String? = nil) -> HubDetail {
            HubDetail(item: item(id), fields: [HubProjectField(id: "due", name: "Due date", options: [], kind: .date)], rows: rows, more: more, cursor: cursor)
        }
        let access = HubAccess(target: RepoTarget(provider: .github, remote: "origin", host: "github.com", path: "team/client"), token: "fixture-credential", apiBase: "https://api.github.com", me: "reviewer")
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("portfolio-local-" + UUID().uuidString).appendingPathComponent("projects.json")
        let localStore = LocalProjectStore(storage: LocalProjectFileStorage(url: localURL)), previousLocalStore = HostingHubAPI.localProjectStore
        HostingHubAPI.localProjectStore = localStore
        defer { HostingHubAPI.localProjectStore = previousLocalStore; try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }
        let localItem = try await localStore.create(title: "Device-only plan")
        let emptyLocal = try await localStore.detail(projectID: localItem.id)
        _ = try await localStore.saveDraft(detail: emptyLocal, title: "Local task", body: "")
        let localAccess = HubAccess(target: RepoTarget(provider: .github, remote: "origin", host: "local", path: "local/workspace"), token: "", apiBase: "", me: "", local: true)
        let localPortfolio = ProjectPortfolioState()
        await localPortfolio.load(localAccess, context: "local")
        precondition(localPortfolio.error == nil && localPortfolio.projects.map(\.id) == [localItem.id] && localPortfolio.details.first?.rows.count == 1, "Guarded local portfolio reads must retain the local backend without an account or network")
        await localPortfolio.refresh(localAccess, context: "local")
        precondition(localPortfolio.projectErrors.isEmpty && localPortfolio.details.first?.rows.first?.title == "Local task")
        var localCurrent = true
        let delayedLocalPage = ReadGate<HubPage>()
        let expiredLocal = ProjectPortfolioState(readPage: { captured, _, _ in
            precondition(captured.local && captured.token.isEmpty && captured.apiBase.isEmpty)
            return await delayedLocalPage.wait()
        }, readDetail: { _, _, _, _ in preconditionFailure("Expired local access must not read details") })
        var guardedLocal = localAccess; guardedLocal.isCurrent = { localCurrent }
        let localPending = Task { await expiredLocal.load(guardedLocal, context: "local") }
        while delayedLocalPage.continuation == nil { await Task.yield() }
        localCurrent = false; delayedLocalPage.finish(HubPage(items: [localItem], more: false)); await localPending.value
        precondition(expiredLocal.projects.isEmpty && expiredLocal.details.isEmpty && !expiredLocal.loading, "Local routing must preserve the same stale-context guards as remote reads")
        var restoredCalls: [String] = []
        let restored = ProjectPortfolioState(readPage: { _, _, _ in HubPage(items: [item("first-page")], more: true, cursor: "next-catalog-page") }, readDetail: { _, selected, _, _ in
            restoredCalls.append(selected.id)
            if selected.id == "removed" { throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not found"]) }
            var result = detail(selected.id, [row("task", "2026-10-28")]); result.item.title = "Actual project title"; return result
        })
        restored.reset(context: "account"); restored.setSelected(["later-page", "removed"])
        await restored.load(access, context: "account")
        precondition(restoredCalls == ["later-page", "removed"] && restored.projects.map(\.title) == ["Project first-page", "Actual project title"])
        precondition(restored.details[0].item.id == "later-page" && restored.projectErrors["removed"] == "Not found" && !restored.projects.contains { $0.id == "removed" } && restored.more, "Restored projects must use real detail metadata without inventing unavailable catalog entries")
        let defaults = MemoryDefaults(), selectionContext = "account-a|repository|github.com|team/client|/fixture/worktree"
        precondition(ProjectPortfolioPreferences.load(context: selectionContext, defaults: defaults) == nil)
        ProjectPortfolioPreferences.save([], context: selectionContext, defaults: defaults)
        precondition(ProjectPortfolioPreferences.load(context: selectionContext, defaults: defaults) == [])
        ProjectPortfolioPreferences.save(["PROJECT_B", "PROJECT_A"], context: selectionContext, defaults: defaults)
        precondition(ProjectPortfolioPreferences.load(context: selectionContext, defaults: defaults) == ["PROJECT_A", "PROJECT_B"])
        precondition(String(data: defaults.values.values.first!, encoding: .utf8) == "[\"PROJECT_A\",\"PROJECT_B\"]", "Only project IDs may be persisted")
        for changed in [selectionContext.replacingOccurrences(of: "account-a", with: "account-b"), selectionContext.replacingOccurrences(of: "repository", with: "personal"), selectionContext.replacingOccurrences(of: "team/client", with: "team/server"), selectionContext.replacingOccurrences(of: "/fixture/worktree", with: "/fixture/other")] {
            precondition(ProjectPortfolioPreferences.load(context: changed, defaults: defaults) == nil)
        }
        let selectionKey = defaults.values.keys.first!
        for invalid in ["invalid JSON", "null", "{}", "[\"A\",1]", "[\"\"]"] {
            defaults.values[selectionKey] = Data(invalid.utf8)
            precondition(ProjectPortfolioPreferences.load(context: selectionContext, defaults: defaults) == nil)
        }
        var calls: [String] = []
        let model = ProjectPortfolioState(readPage: { _, _, _ in HubPage(items: ["a", "b", "c", "d"].map(item), more: false) }, readDetail: { _, selected, _, _ in calls.append(selected.id); return detail(selected.id, [row(selected.id)]) })
        await model.load(access, context: "account")
        precondition(model.selectedIDs == ["a", "b", "c"] && calls == ["a", "b", "c"])
        model.setSelected(["a", "b", "c", "d"])
        await model.refresh(access, context: "account")
        precondition(model.details.count == 4, "Selection must not have an artificial maximum")
        model.setSelected([])
        await model.load(access, context: "account")
        precondition(model.selectedIDs.isEmpty && model.details.isEmpty, "Explicit empty selection must remain empty")

        let oldPage = ReadGate<HubPage>()
        let switched = ProjectPortfolioState(readPage: { c, _, _ in c.me == "old" ? await oldPage.wait() : HubPage(items: [item("new")], more: false) }, readDetail: { _, selected, _, _ in detail(selected.id, [row(selected.id)]) })
        let oldAccess = HubAccess(target: access.target, token: access.token, apiBase: access.apiBase, me: "old")
        let old = Task { await switched.load(oldAccess, context: "old-account") }
        while oldPage.continuation == nil { await Task.yield() }
        switched.reset(context: "new-account")
        precondition(switched.projects.isEmpty && switched.details.isEmpty && switched.error == nil)
        await switched.load(access, context: "new-account")
        oldPage.finish(HubPage(items: [item("old")], more: true))
        await old.value
        precondition(switched.projects.map(\.id) == ["new"] && switched.details.map { $0.item.id } == ["new"] && !switched.loading, "An old account's response must never reappear")

        var failB = true, count = 0
        let delayed = ReadGate<HubDetail>()
        let partial = ProjectPortfolioState(readPage: { _, _, _ in HubPage(items: [item("a"), item("b")], more: false) }, readDetail: { _, selected, _, _ in
            if selected.id == "b" && failB { throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unavailable " + access.token]) }
            if selected.id == "a" { count += 1; if count == 2 { return await delayed.wait() } }
            return detail(selected.id, [row(selected.id + "-" + String(count))])
        })
        await partial.load(access, context: "account")
        precondition(partial.details.map { $0.item.id } == ["a"] && partial.projectErrors["b"] == "Unavailable [redacted]")
        let staleRefresh = Task { await partial.refresh(access, context: "account") }
        while delayed.continuation == nil { await Task.yield() }
        failB = false
        await partial.refresh(access, context: "account")
        delayed.finish(detail("a", [row("stale")]))
        await staleRefresh.value
        precondition(partial.projectErrors.isEmpty && partial.details.count == 2 && !partial.details.flatMap(\.rows).contains { $0.id == "stale" } && !partial.loading)

        var pages: [String] = []
        let paged = ProjectPortfolioState(readPage: { _, page, cursor in pages.append("catalog:\(page):\(cursor ?? "")"); return page == 1 ? HubPage(items: [item("a")], more: true, cursor: "catalog-next") : HubPage(items: [item("a"), item("b")], more: false) }, readDetail: { _, selected, page, cursor in pages.append("\(selected.id):\(page):\(cursor ?? "")"); return page == 1 ? detail(selected.id, [row("one", "2026-10-27")], more: true, cursor: "items-next") : detail(selected.id, [row("one"), row("two", "2026-10-28")]) })
        await paged.load(access, context: "account")
        await paged.loadMoreItems(access, context: "account", projectID: "a")
        precondition(paged.details[0].rows.map(\.id) == ["one", "two"] && !paged.details[0].more && paged.details[0].rows[0].values["due"] == "2026-10-27")
        await paged.load(access, context: "account", appendProjects: true)
        precondition(paged.projects.map(\.id) == ["a", "b"] && !paged.more && pages.contains("a:2:items-next") && pages.contains("catalog:2:catalog-next"))

        var current = true
        let guardedPage = ReadGate<HubPage>()
        let expired = ProjectPortfolioState(readPage: { _, _, _ in await guardedPage.wait() }, readDetail: { _, _, _, _ in preconditionFailure("Expired access must never start another request") })
        let guarded = HubAccess(target: access.target, token: access.token, apiBase: access.apiBase, me: access.me, isCurrent: { current })
        let pending = Task { await expired.load(guarded, context: "account") }
        while guardedPage.continuation == nil { await Task.yield() }
        current = false; guardedPage.finish(HubPage(items: [item("private")], more: false)); await pending.value
        precondition(expired.projects.isEmpty && expired.details.isEmpty && !expired.loading)

        let sharedURL = "https://github.com/team/client/issues/1"
        let records = [detail("a", [row("a-one", "2026-10-29", contentID: "content", url: sharedURL), row("draft", contentID: "same-draft", kind: .draft)]), detail("b", [row("b-one", "2026-10-27", contentID: "content", url: sharedURL), row("draft", contentID: "same-draft", kind: .draft), row("archived", archived: true), row("private", kind: .redacted)])]
        let tasks = ProjectPortfolio.tasks(records)
        precondition(tasks.count == 3 && tasks[0].detail.item.id == "b" && tasks[0].entry.due == "2026-10-27" && tasks[0].projectNames == ["Project a", "Project b"])
        precondition(ProjectPortfolio.tasks(records.reversed()).map(\.id) == tasks.map(\.id) && tasks.filter { $0.entry.row.kind == .draft }.count == 2)
        var closedRow = row("closed", "2026-10-01", contentID: "shared", url: sharedURL); closedRow.state = "CLOSED"
        var activeRow = row("open", "2026-11-01", contentID: "shared", url: sharedURL); activeRow.state = "OPEN"
        let activeTask = ProjectPortfolio.tasks([detail("done", [closedRow]), detail("active", [activeRow])])[0]
        precondition(!activeTask.entry.completed && activeTask.entry.due == "2026-11-01" && activeTask.detail.item.id == "active" && activeTask.projectNames == ["Project active", "Project done"], "A completed membership must not hide active work or supply its overdue date")
        activeRow.state = "CLOSED"
        let completedTask = ProjectPortfolio.tasks([detail("done", [closedRow]), detail("active", [activeRow])])[0]
        precondition(completedTask.entry.completed && completedTask.entry.due == "2026-10-01")
        let urls = ProjectPortfolio.tasks([detail("a", [row("a", "2026-02-30", contentID: "one", url: sharedURL)]), detail("b", [row("b", "2026-10-30", contentID: "", url: sharedURL + "/?tracking=1#body")]), detail("c", [row("c", "2026-10-28", contentID: "one", url: "https://code.example.com/team/client/issues/1")])])
        precondition(urls.count == 2 && urls[0].detail.item.id == "c" && urls[1].detail.item.id == "b" && urls[1].projectNames == ["Project a", "Project b"])
        print("Project portfolio: account reset, stale reads, latest refresh, partial failures, isolated selection, truthful pagination and actual-date task deduplication passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/Services/HostingHub.swift" "${PROJECT_BACKEND_TEST_SOURCES[@]}" "$ROOT/Sources/Core/ProjectPortfolioPreferences.swift" "$ROOT/Sources/Services/ProjectPortfolio.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-project-portfolio"
"$TASK_TMP/test-project-portfolio"
