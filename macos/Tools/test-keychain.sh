#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
python3 - "$ROOT/Sources/Services/Accounts.swift" "$TASK_TMP/Keychain.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
keychain, delimiter, _ = source.partition('/// GitHub·사내 GitLab 계정')
assert delimiter and 'enum Keychain {' in keychain
Path(sys.argv[2]).write_text(keychain)
PY
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
@main struct KeychainTests {
    static func main() async {
        let name = "selftest-keychain-" + UUID().uuidString
        defer { Task { await Keychain.set(nil, for: name) } }
        let created = await Keychain.set("test-one", for: name)
        precondition(created, "Keychain creation failed")
        let first = await Keychain.get(name)
        precondition(first == "test-one", "Keychain read failed")
        let updated = await Keychain.set("test-two", for: name)
        precondition(updated, "Keychain update failed")
        let second = await Keychain.get(name)
        precondition(second == "test-two", "Keychain replacement failed")
        let removed = await Keychain.set(nil, for: name)
        precondition(removed, "Keychain cleanup failed")
        let missing = await Keychain.get(name)
        precondition(missing == nil, "Keychain item remained")
        let removedAgain = await Keychain.set(nil, for: name)
        precondition(removedAgain, "Keychain deletion was not idempotent")
        print("macOS Keychain: unique credential create/read/update/delete and idempotent cleanup passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$TASK_TMP/Keychain.swift" "$ROOT/Sources/Core/LegacyData.swift" "$ROOT/Sources/Core/CredentialCache.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-keychain"
"$TASK_TMP/test-keychain"
