import Foundation

/// In-memory records for the added sheets; the demo never touches local documents or the real database.
/// Windows: entities/ledger/api/demo-extras.ts.
final class LedgerDemoExtras {
    private var notes: [LedgerJSON] = []
    private var items: [LedgerJSON] = []
    private var records: [LedgerJSON] = []
    private var summaries: [String: LedgerJSON] = [:]
    private var summaryRequests = 0
    private var summaryInput = 0
    private var summaryOutput = 0
    private var roots: [String: [LedgerJSON]] = [:]

    func call(_ method: String, _ a: LedgerJSON, now: LedgerMs) throws -> LedgerJSON {
        let action = a["action"].string ?? "list"
        if method == "notebook" {
            let note = notes.first { $0["id"] == a["id"] }
            if action == "list" {
                let query = a["query"].string?.lowercased() ?? ""
                let rows = notes.filter { query.isEmpty || (($0["title"].string ?? "") + "\n" + ($0["body"].string ?? "")).lowercased().contains(query) }
                    .sorted { left, right in
                        if left["pinned"].bool != right["pinned"].bool { return left["pinned"].bool == true }
                        return (left["updatedAt"].int ?? 0) > (right["updatedAt"].int ?? 0)
                    }
                return ["notes": .array(rows)]
            }
            if action == "get" { return ["note": note ?? .null] }
            if let note, a["expectedUpdatedAt"] != note["updatedAt"] {
                throw LedgerFailure(code: "CONFLICT", message: "This note changed. Reload it before saving.")
            }
            if action == "delete" { notes.removeAll { $0["id"] == a["id"] }; return ["ok": true] }
            let id = note?["id"].int ?? ((notes.compactMap { $0["id"].int }.max() ?? 0) + 1)
            let saved: LedgerJSON = ["id": .number(Double(id)), "title": a["title"], "body": a["body"], "pinned": a["pinned"], "createdAt": note?["createdAt"] ?? .number(Double(now)), "updatedAt": .number(Double(max(now, (note?["updatedAt"].int ?? 0) + 1)))]
            notes.removeAll { $0["id"].int == id }; notes.append(saved)
            return ["note": saved]
        }
        let project = a["project"].string ?? "atlas"
        if method == "documents" {
            if action == "set_roots" { roots[project] = a["roots"].array }
            let folders = roots[project] ?? []
            let key = project + ":" + (a["id"].string ?? a["path"].string ?? "")
            if action == "summary_save" {
                summaries[key] = ["text": a["text"], "provider": a["provider"], "model": a["model"], "createdAt": .number(Double(now)), "requestChars": a["requestChars"], "responseChars": a["responseChars"]]
                summaryRequests += 1; summaryInput += a["requestChars"].int ?? 0; summaryOutput += a["responseChars"].int ?? 0
            }
            let usage: LedgerJSON = ["month": "2026-11", "requests": .number(Double(summaryRequests)), "requestChars": .number(Double(summaryInput)), "responseChars": .number(Double(summaryOutput))]
            if action == "usage" { return ["usage": usage] }
            if action == "summary_get" || action == "summary_save" { return ["key": .string(key), "summary": summaries[key] ?? .null, "usage": usage] }

            let entry: LedgerJSON = ["id": "DOC-12", "line": 3, "text": "- [ ] DOC-12: Review the cache policy", "heading": "Directive", "definition": true, "kind": "directive", "status": "open", "task": true, "root": folders.first ?? "", "path": "plan.md", "hash": "demo", "changed": false]
            return ["project": .string(project), "roots": .array(folders), "files": [], "ids": .array(folders.isEmpty ? [] : ["DOC-12"]), "entries": .array(folders.isEmpty ? [] : [entry]), "relatedSessions": [], "total": .number(folders.isEmpty ? 0 : 1), "truncated": false, "warnings": []]
        }
        let scoped = items.filter { $0["project"].string == project }
        if action == "list" { return ["project": .string(project), "items": .array(scoped), "bundles": [], "warnings": [], "notes": []] }
        if action == "detail" { return ["item": scoped.first { $0["id"] == a["item"] } ?? .null, "events": .array(records.filter { $0["item"] == a["item"] }), "history": []] }
        if action == "unassigned" { return ["events": []] }
        if action == "report" { return ["markdown": .string("# " + project + "\n\n" + scoped.map { "- \($0["title"].string ?? ""): \($0["status"].string ?? "")" }.joined(separator: "\n"))] }
        if action == "add_item" { items.append(["id": a["item"], "project": .string(project), "title": a["title"], "bundle": a["bundle"], "output": a["output"], "status": "planned"]) }
        if action == "event", a["event"].string == "completed", let index = items.firstIndex(where: { $0["id"] == a["item"] }), var values = items[index].object {
            values["status"] = "completed"; items[index] = .object(values)
        }
        let record: LedgerJSON = ["id": .number(Double(records.count + 1)), "item": a["item"], "date": a["date"], "event": action == "add_item" ? "registered" : a["event"], "text": a["text"], "refs": a["refs"]]
        records.append(record)
        return ["ok": true, "eventId": record["id"], "results": []]
    }
}
