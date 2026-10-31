import Foundation
import GitrochiCore

/// The ledger core itself (crates/gitrochi-ledger) through its C ABI, which libgitrochi_core.a re-exports:
/// `gitrochi_ledger_call(method, json)` answers with a JSON string that `gitrochi_ledger_free` releases. A call may wait
/// on the database, so LedgerClient makes it off the main thread; the core is safe from several threads. The database
/// is the core's default (Application Support/Gitrochi/ledger) unless GITROCHI_LEDGER_DB names another one, and
/// GITROCHI_LEDGER=0 turns the core off. (Windows: src-tauri/src/ledger.rs, the `ledger_call` command)
final class NativeLedgerBackend: LedgerBackend {
    /// Another database for every call (the contract's `db` argument); for tests and tools, the app never sets it
    let database: String?

    init(database: String? = nil) {
        self.database = database
    }

    func call(method: String, args: Data) -> Data {
        let json = String(decoding: withDatabase(args), as: UTF8.self)
        let result = method.withCString { method in json.withCString { json in gitrochi_ledger_call(method, json) } }
        defer { gitrochi_ledger_free(result) }
        return Data(bytes: result, count: strlen(result))
    }

    private func withDatabase(_ args: Data) -> Data {
        guard let database, var object = (try? JSONSerialization.jsonObject(with: args)) as? [String: Any] else { return args }
        object["db"] = database
        return (try? JSONSerialization.data(withJSONObject: object)) ?? args
    }
}
