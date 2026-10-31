import Foundation

/// The `gitrochi-ledger` command the app bundles in Contents/MacOS. Claude Code starts it as an MCP server
/// (`gitrochi-ledger mcp`); the Connect Claude Code sheet checks it the way such a client would.
/// (Windows: the bundled gitrochi-ledger.exe and features/connect-ledger-mcp)
enum LedgerCommandLine {
    static var bundled: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/gitrochi-ledger") }

    /// Starts `<binary> mcp`, sends the MCP handshake and `tools/list`, and answers with the tool names. The server
    /// exits when its input ends; one that hangs is stopped after `timeout` seconds.
    static func tools(binary: URL, timeout: TimeInterval = 10) async throws -> [String] {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw LedgerFailure(code: "NOT_FOUND", message: String(localized: "The ledger command is missing from this copy of Gitrochi: \(binary.path)"))
        }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["mcp"]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let requests = [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Gitrochi","version":"1"}}}"#,
                #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            ]
            input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
            try? input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let message = try? JSONDecoder().decode(LedgerJSON.self, from: Data(line)), message["id"].int == 2 else { continue }
                if let error = message["error"]["message"].string { throw LedgerFailure(code: "MCP", message: error) }
                return message["result"]["tools"].array.compactMap { $0["name"].string }
            }
            throw LedgerFailure(code: "MCP", message: String(localized: "The ledger command did not answer the MCP handshake."))
        }.value
    }
}
