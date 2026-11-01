#!/usr/bin/env bash
# The copied setup status command must never uninstall tracking.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}

let binary = "/Applications/Team's $Tools/Gitrochi.app/Contents/MacOS/gitrochi-ledger"
for client in LedgerSetupClient.allCases {
    let status = client.status(binary: binary)
    let remove = client.remove(binary: binary)
    expect(status.hasSuffix(" integrate \(client.rawValue) --status"), "Status must inspect the chosen client")
    expect(!status.contains("--remove") && !status.contains("\n"), "Copying Status must never remove tracking")
    expect(remove.hasSuffix(" integrate \(client.rawValue) --remove"), "Remove must remove only the chosen client's owned hooks")
    expect(!remove.contains("--status") && !remove.contains("\n"), "Remove must have its own copy block")
    expect(status.contains("Team'\\''s $Tools"), "Paths must remain literal shell arguments")
}
print("PASS: separate status and removal commands for both Ledger clients")
SWIFT
swiftc -module-cache-path "$TASK_TMP/cache" "$TASK_ROOT/macos/Sources/Services/LedgerConnectionSetup.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/check"
"$TASK_TMP/check"
