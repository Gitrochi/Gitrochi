import Foundation
import Observation

/// A deduplicated task retains the project whose actual date is used by the portfolio.
struct ProjectPortfolioTask: Identifiable {
    var id: String
    var detail: HubDetail
    var entry: ProjectScheduleEntry
    var projectNames: [String]
}

enum ProjectPortfolio {
    static func tasks(_ details: [HubDetail], settingsByProject: [String: ProjectScheduleSettings] = [:]) -> [ProjectPortfolioTask] {
        var groups: [[ProjectPortfolioTask]] = [], aliases: [String: Int] = [:]
        for detail in details.sorted(by: { $0.item.id < $1.item.id }) {
            for entry in ProjectSchedule.entries(detail.rows, fields: detail.fields, settings: settingsByProject[detail.item.id] ?? .init()).sorted(by: { $0.id < $1.id }) {
                let keys = identity(entry.row, projectID: detail.item.id)
                let matches = Set(keys.compactMap { aliases[$0] }).sorted()
                let index = matches.first ?? groups.count
                if index == groups.count { groups.append([]) }
                for old in matches.dropFirst() {
                    groups[index] += groups[old]; groups[old] = []
                    for (key, value) in aliases where value == old { aliases[key] = index }
                }
                groups[index].append(ProjectPortfolioTask(id: keys[0], detail: detail, entry: entry, projectNames: [detail.item.title]))
                for key in keys { aliases[key] = index }
            }
        }
        return groups.filter { !$0.isEmpty }.map { group in
            let active = group.filter { !$0.entry.completed }
            let sorted = (active.isEmpty ? group : active).sorted { lhs, rhs in
                let left = lhs.entry.invalidRange ? nil : lhs.entry.date, right = rhs.entry.invalidRange ? nil : rhs.entry.date
                if left != right { return (left ?? "99999") < (right ?? "99999") }
                if lhs.detail.item.id != rhs.detail.item.id { return lhs.detail.item.id < rhs.detail.item.id }
                return lhs.entry.id < rhs.entry.id
            }
            var task = sorted[0]
            task.entry.completed = active.isEmpty
            task.id = group.map(\.id).sorted()[0]
            task.projectNames = Array(Set(group.flatMap(\.projectNames))).sorted()
            return task
        }.sorted {
            let left = $0.entry.invalidRange ? nil : $0.entry.date, right = $1.entry.invalidRange ? nil : $1.entry.date
            if left != right { return (left ?? "99999") < (right ?? "99999") }
            return $0.id < $1.id
        }
    }

    private static func identity(_ row: HubProjectRow, projectID: String) -> [String] {
        if row.kind == .draft { return ["draft:\(projectID):\(row.id)"] }
        var keys: [String] = []
        var components = URLComponents(string: row.url)
        let host = components?.host?.lowercased() ?? ""
        if !row.contentID.isEmpty { keys.append("content:\(host):\(row.contentID)") }
        if components?.scheme?.lowercased() == "https", !host.isEmpty {
            components?.host = host; components?.query = nil; components?.fragment = nil
            if components?.port == 443 { components?.port = nil }
            while components?.path.hasSuffix("/") == true { components?.path.removeLast() }
            if let url = components?.string { keys.append("url:" + url) }
        }
        return keys.isEmpty ? ["item:\(projectID):\(row.id)"] : keys
    }
}

/// Home reads have their own context, pagination and failures, independent of the project editor.
@MainActor @Observable final class ProjectPortfolioState {
    var projects: [HubItem] = []
    var details: [HubDetail] = []
    var selectedIDs = Set<String>()
    var loading = false
    var error: String?
    var projectErrors: [String: String] = [:]
    var more = false

    @ObservationIgnored private var context = ""
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var catalogPage = 0
    @ObservationIgnored private var catalogCursor: String?
    @ObservationIgnored private var itemPages: [String: Int] = [:]
    @ObservationIgnored private var selectionEstablished = false
    @ObservationIgnored private let readPage: (HubAccess, Int, String?) async throws -> HubPage
    @ObservationIgnored private let readDetail: (HubAccess, HubItem, Int, String?) async throws -> HubDetail

    init(readPage: @escaping (HubAccess, Int, String?) async throws -> HubPage = { try await HostingHubAPI.page($0, section: .projects, page: $1, cursor: $2) },
         readDetail: @escaping (HubAccess, HubItem, Int, String?) async throws -> HubDetail = { try await HostingHubAPI.detail($0, section: .projects, item: $1, page: $2, cursor: $3) }) {
        self.readPage = readPage; self.readDetail = readDetail
    }

    func reset(context: String) {
        self.context = context; generation = UUID(); requestID = UUID()
        projects = []; details = []; selectedIDs = []; loading = false; error = nil; projectErrors = [:]; more = false
        catalogPage = 0; catalogCursor = nil; itemPages = [:]; selectionEstablished = false
    }

    func setSelected(_ ids: Set<String>) {
        requestID = UUID(); loading = false; selectionEstablished = true; selectedIDs = ids
        details.removeAll { !ids.contains($0.item.id) }
        projectErrors = projectErrors.filter { ids.contains($0.key) }
        itemPages = itemPages.filter { ids.contains($0.key) }
    }

    func load(_ c: HubAccess, context: String, appendProjects: Bool = false) async {
        if self.context != context { reset(context: context) }
        if appendProjects && catalogPage > 0 && !more { return }
        let id = UUID(), generation = self.generation; requestID = id; loading = true
        let access = guarded(c, generation: generation, requestID: id)
        defer { if self.generation == generation && requestID == id { loading = false } }
        do {
            try HostingHubAPI.check(access)
            let page = try await readPage(access, appendProjects ? catalogPage + 1 : 1, appendProjects ? catalogCursor : nil)
            guard current(access, generation: generation, requestID: id) else { return }
            projects = appendProjects ? projects + page.items.filter { next in !projects.contains { $0.id == next.id } } : page.items
            catalogPage = appendProjects ? catalogPage + 1 : 1; catalogCursor = page.cursor; more = page.more; error = nil
            if !selectionEstablished { selectedIDs = Set(projects.prefix(3).map(\.id)); selectionEstablished = true }
            await readSelected(access, generation: generation, requestID: id)
        } catch { if current(access, generation: generation, requestID: id) { self.error = HostingHubAPI.error(error, token: c.token) } }
    }

    func refresh(_ c: HubAccess, context: String) async {
        if self.context != context { reset(context: context) }
        let id = UUID(), generation = self.generation; requestID = id; loading = true
        let access = guarded(c, generation: generation, requestID: id)
        defer { if self.generation == generation && requestID == id { loading = false } }
        await readSelected(access, generation: generation, requestID: id)
    }

    func loadMoreItems(_ c: HubAccess, context: String, projectID: String) async {
        if self.context != context { reset(context: context); return }
        guard !loading, selectedIDs.contains(projectID), let previous = details.first(where: { $0.item.id == projectID }), previous.more else { return }
        let id = UUID(), generation = self.generation; requestID = id; loading = true
        let access = guarded(c, generation: generation, requestID: id)
        defer { if self.generation == generation && requestID == id { loading = false } }
        do {
            try HostingHubAPI.check(access)
            var next = try await readDetail(access, previous.item, (itemPages[projectID] ?? 1) + 1, previous.cursor)
            guard current(access, generation: generation, requestID: id), selectedIDs.contains(projectID) else { return }
            next.rows = previous.rows + next.rows.filter { row in !previous.rows.contains { $0.id == row.id } }
            if let index = details.firstIndex(where: { $0.item.id == projectID }) { details[index] = next }
            itemPages[projectID] = (itemPages[projectID] ?? 1) + 1; projectErrors[projectID] = nil
        } catch { if current(access, generation: generation, requestID: id) { projectErrors[projectID] = HostingHubAPI.error(error, token: c.token) } }
    }

    private func readSelected(_ c: HubAccess, generation: UUID, requestID: UUID) async {
        let known = projects.filter { selectedIDs.contains($0.id) }
        let missing = selectedIDs.subtracting(Set(known.map(\.id))).sorted().map { HubItem(id: $0, title: "") }
        for item in known + missing {
            guard current(c, generation: generation, requestID: requestID) else { return }
            do {
                let detail = try await readDetail(c, item, 1, nil)
                guard current(c, generation: generation, requestID: requestID), selectedIDs.contains(item.id) else { return }
                guard detail.item.id == item.id else { throw HostingHubAPI.fail(String(localized: "Project is unavailable or this account cannot access it.")) }
                if let index = details.firstIndex(where: { $0.item.id == item.id }) { details[index] = detail } else { details.append(detail) }
                if let index = projects.firstIndex(where: { $0.id == item.id }) { projects[index] = detail.item } else { projects.append(detail.item) }
                itemPages[item.id] = 1; projectErrors[item.id] = nil
            } catch { if current(c, generation: generation, requestID: requestID) { projectErrors[item.id] = HostingHubAPI.error(error, token: c.token) } }
        }
        if current(c, generation: generation, requestID: requestID) { details.sort { $0.item.id < $1.item.id } }
    }

    private func guarded(_ c: HubAccess, generation: UUID, requestID: UUID) -> HubAccess {
        HubAccess(target: c.target, token: c.token, apiBase: c.apiBase, me: c.me, isCurrent: { [weak self] in
            c.isCurrent?() != false && !Task.isCancelled && self?.generation == generation && self?.requestID == requestID
        }, local: c.local)
    }
    private func current(_ c: HubAccess, generation: UUID, requestID: UUID) -> Bool {
        !Task.isCancelled && self.generation == generation && self.requestID == requestID && c.isCurrent?() != false
    }
}
