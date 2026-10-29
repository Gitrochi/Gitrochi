#!/usr/bin/env bash
# Render actual PR and organization screens using isolated, deterministic data and disabled networking.
# Optional: GITROCHI_REQUEST_LAYOUT_SCENARIOS=organizations,members for a targeted render.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d /tmp/gitrochi-request-layout-source.XXXXXX)"
trap 'if [[ -z "${GITROCHI_REQUEST_LAYOUT_KEEP_SOURCES:-}" ]]; then rm -rf "$TASK_TMP"; else echo "Fixture sources retained: $TASK_TMP" >&2; fi' EXIT
TASK_OUTPUT="${1:-$(mktemp -d /tmp/gitrochi-request-layout.XXXXXX)}"
mkdir -p "$TASK_OUTPUT"
ARCH="$(uname -m)"
TASK_SWIFTTERM="$ROOT/.build/swiftterm/$ARCH"
ST="$TASK_TMP/swiftterm"
case "$ARCH" in arm64) TASK_TARGET=aarch64-apple-darwin ;; x86_64) TASK_TARGET=x86_64-apple-darwin ;; *) exit 1 ;; esac
TASK_CORE="$ROOT/../crates/target/$TASK_TARGET/release/libgitrochi_core.a"
[[ -f "$TASK_SWIFTTERM/libSwiftTerm.a" && -f "$TASK_CORE" ]] || { echo "Run macos/build.sh once before rendering fixtures." >&2; exit 1; }
cp -R "$TASK_SWIFTTERM" "$ST"
python3 - "$ROOT" "$TASK_TMP" <<'PY'
from pathlib import Path
import sys
root, target = map(Path, sys.argv[1:])

def replace_body(text, signature, body):
    start = text.index(signature)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if text[end] == '{': depth += 1
        elif text[end] == '}': depth -= 1
        end += 1
    return text[:opening + 1] + '\n' + body + '\n    }' + text[end:]

for source in (root / 'Sources').rglob('*.swift'):
    relative = source.relative_to(root / 'Sources').as_posix()
    text = source.read_text().replace('UserDefaults.standard', 'requestFixtureDefaults')
    if relative == 'App/App.swift':
        start = text.index('@main\nstruct GitrochiApp: App {')
        end = text.index('/// 창(탭) 하나 = 저장소 하나', start)
        text = text[:start] + text[end:]
    elif relative == 'Services/Accounts.swift':
        text = text.replace('        Askpass.install()', '        // Disabled in deterministic fixture.')
        text = replace_body(text, '    func token(for a: HostAccount)', '        return \"fixture-value\"')
        text += '\nextension AccountStore { func fixtureAccounts(_ values: [HostAccount]) { accounts = values } }\n'
    elif relative == 'Services/AvatarStore.swift':
        # Keep initials deterministic without disk caches or external image requests.
        text = replace_body(text, '    func image(for rawEmail:', '        return nil')
    elif relative == 'Services/Tools.swift':
        text = replace_body(text, '    private init()', '        states[.git] = State(path: "/usr/bin/git", source: .auto, version: "fixture")')
    elif relative == 'Services/Hosting.swift':
        text = replace_body(text, '    static func data(_ req: URLRequest)', '        throw NSError(domain: "RequestLayoutFixture.NetworkDisabled", code: 1)')
    elif relative == 'Store/RepoStore+CI.swift':
        text = replace_body(text, '    func loadCI(silent: Bool = false, withJobs: Bool = true)', '        // Fixture state is supplied by the renderer.')
        text = replace_body(text, '    func loadJobs(_ p: CIPipeline, silent: Bool = false)', '        // Fixture state is supplied by the renderer.')
    elif relative == 'Views/Workspace/CIRunDetailView.swift':
        text = replace_body(text, '    private func load() async', '        text = "Build started\\nChecking workspace\\nFAIL: Update the dependency lockfile\\nProcess exited with code 1"; loadedJob = job.id; busy = false; error = nil')
    elif relative == 'Store/RepoStore+Review.swift':
        text = replace_body(text, '    func loadReview(_ number: Int)', '        // Fixture state is supplied by the renderer.')
    elif relative == 'Store/RepoStore+Collaboration.swift':
        text = replace_body(text, '    func loadRequestLifecycle(_ number: Int)', '        // Fixture state is supplied by the renderer.')
    elif relative == 'Store/RepoStore+Integrations.swift':
        text = replace_body(text, '    func loadPullRequests(append: Bool = false)', '        // Fixture state is supplied by the renderer.')
    elif relative == 'Store/RepoStore+HostingHub.swift':
        text = replace_body(text, '    func activateHostingHub(_ section: HostingHubSection)', '        // Fixture state is supplied by the renderer.')
    elif relative == 'Views/Inspector/PullRequestDetailView.swift':
        text = text.replace('draft = ""; tab = "conversation"; await store.loadReview(number)', 'draft = ""; tab = requestFixtureDetailTab; await store.loadReview(number)')
        text = text.replace('.task(id: reviewContext) { await store.loadReview(number) }', '.task(id: reviewContext) { tab = requestFixtureDetailTab; await store.loadReview(number) }')
    elif relative == 'Views/Inspector/RequestChecksPanel.swift':
        text = replace_body(text, '    @MainActor private func load() async', '        results = requestFixtureChecks\n        logs = ["build": WorkspaceCILog.Result(body: "Building Gitrochi\\nTESTS PASSED\\nAll checks completed", truncated: false)]\n        loading = false; error = nil')
        text = text.replace('DisclosureGroup("Job log") {', 'DisclosureGroup("Job log", isExpanded: .constant(true)) {')
    elif relative == 'Views/Shared/MarkdownView.swift':
        # Exercise the loaded-image layout without external HTTP or authentication.
        text = replace_body(text, '    private func load() async', '        image = requestFixtureImage; loading = false')
    elif relative == 'Views/Shared/HostingAvatar.swift':
        # Exercise loaded member photos and organization logos without external image requests.
        original = 'AsyncImage(url: AvatarStore.shared.enabled ? avatarURL : nil)'
        assert original in text, 'HostingAvatar loader changed; update deterministic image injection.'
        text = text.replace(original, 'RequestFixtureAvatarImage(url: AvatarStore.shared.enabled ? avatarURL : nil)')
    dest = target / 'Sources' / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text)
with (target / 'Sources/Store/RepoStore.swift').open('a') as f:
    f.write('''
extension RepoStore {
    func fixtureRepository() {
        url = URL(fileURLWithPath: "/fixture/Gitrochi")
        headBranch = "main"
    }
}
''')
PY
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$TASK_TMP/Sources" -name '*.swift' -print0)
cp "$TASK_CORE" "$TASK_TMP/core.a"
cp "$ROOT/Tools/fixtures/RequestLayout.swift" "$TASK_TMP/RequestLayout.swift"
echo "Fixture sources: $TASK_TMP"
xcrun swiftc -parse-as-library -swift-version 5 -whole-module-optimization -Onone -target "$ARCH-apple-macos15.0" \
    -I "$ST" -I "$ROOT/../crates/gitrochi-core/include" -L "$ST" -lSwiftTerm \
    "${SOURCES[@]}" "$TASK_TMP/RequestLayout.swift" "$TASK_TMP/core.a" -o "$TASK_TMP/request-layout"
"$TASK_TMP/request-layout" "$TASK_OUTPUT"
