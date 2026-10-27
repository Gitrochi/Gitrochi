#!/usr/bin/env bash
# Verify persisted create-attempt locks using production models and an isolated defaults suite.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
python3 - "$ROOT" "$TASK_TMP" <<'PY'
from pathlib import Path
import sys
root, target = map(Path, sys.argv[1:])
models = (root / 'Sources/Core/Models.swift').read_text()
start = models.index('enum Provider: String,')
end = models.index('\n/// 열린 저장소의 원격이 가리키는 호스팅 저장소', start)
item = next(line for line in (root / 'Sources/Services/HostingHub.swift').read_text().splitlines() if line.startswith('struct HubItem:'))
(target / 'Models.swift').write_text('import Foundation\n' + models[start:end].replace('UserDefaults.standard', 'recoveryFixtureDefaults') + '\n' + item + '\n')
source = (root / 'Sources/Services/ProjectCreationRecovery.swift').read_text().replace('UserDefaults.standard', 'recoveryFixtureDefaults')
(target / 'ProjectCreationRecovery.swift').write_text(source)
PY
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import Foundation
let recoveryFixtureSuite = "dev.gitrochi.project-creation-recovery-tests." + UUID().uuidString
var recoveryFixtureDefaults = UserDefaults(suiteName: recoveryFixtureSuite)!
@main struct CreationRecoveryTests {
    @MainActor static func main() {
        defer { recoveryFixtureDefaults.removePersistentDomain(forName: recoveryFixtureSuite) }
        let account = HostAccount(id: "fixture-account", provider: .github, server: "https://github.com", username: "demo-reader", name: nil, avatarURL: nil)
        let other = HostAccount(id: "other-account", provider: .github, server: "https://github.com", username: "demo-reader", name: nil, avatarURL: nil)
        let otherHost = HostAccount(id: account.id, provider: .github, server: "https://git.example.com", username: "demo-reader", name: nil, avatarURL: nil)
        precondition(ProjectCreationRecovery.load(account, owner: "sample-team") == nil)
        ProjectCreationRecovery.save(account, owner: "Sample-Team", title: "Release planning")
        recoveryFixtureDefaults = UserDefaults(suiteName: recoveryFixtureSuite)!
        let pending = ProjectCreationRecovery.load(account, owner: "sample-team")
        precondition(pending?.title == "Release planning" && pending?.project == nil, "An unresolved attempt must survive reopening before a project ID is known")
        precondition(ProjectCreationRecovery.load(account, owner: "another-team") == nil && ProjectCreationRecovery.load(other, owner: "sample-team") == nil && ProjectCreationRecovery.load(otherHost, owner: "sample-team") == nil, "Pending creation must be isolated by account, host and owner")
        let created = HubItem(id: "fixture-project", title: "Release planning", url: "https://github.com/orgs/sample-team/projects/12", data: ["privateMetadata": "must-not-persist"])
        ProjectCreationRecovery.save(account, owner: "sample-team", title: "Release planning", project: created)
        recoveryFixtureDefaults = UserDefaults(suiteName: recoveryFixtureSuite)!
        let recovered = ProjectCreationRecovery.load(account, owner: "SAMPLE-TEAM")
        precondition(recovered?.project?.id == created.id && recovered?.project?.url == created.url && recovered?.project?.data.isEmpty == true, "Partial creation recovery keeps only identity, URL and title")
        ProjectCreationRecovery.save(other, owner: "sample-team", title: "Other account")
        ProjectCreationRecovery.save(account, owner: "another-team", title: "Another owner")
        ProjectCreationRecovery.clear(account, owner: "sample-team")
        precondition(ProjectCreationRecovery.load(account, owner: "sample-team") == nil && ProjectCreationRecovery.load(other, owner: "sample-team")?.title == "Other account" && ProjectCreationRecovery.load(account, owner: "another-team")?.title == "Another owner", "Reconciling an attempt must not unlock another destination")
        ProjectCreationRecovery.save(account, owner: "sample-team", title: "Second attempt", project: created)
        ProjectCreationRecovery.save(account, owner: "sample-team", title: "New unresolved attempt")
        precondition(ProjectCreationRecovery.load(account, owner: "sample-team")?.project == nil, "A new unresolved attempt must not reuse a previous project ID")
        print("Project creation recovery: persisted unresolved and partial attempts, account/host/owner isolation, minimal metadata and destination-specific reconciliation passed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 "$TASK_TMP/Models.swift" "$TASK_TMP/ProjectCreationRecovery.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/test-project-creation-recovery"
"$TASK_TMP/test-project-creation-recovery"
