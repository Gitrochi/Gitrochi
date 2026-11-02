#!/usr/bin/env bash
# Exercise the production launch branches without real agents, Ledger calls or terminal windows.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
python3 - "$ROOT" "$TASK_TMP" <<'PY'
from pathlib import Path
import sys

root, target = map(Path, sys.argv[1:])
source = (root / 'Sources/Services/Agents.swift').read_text()

def method(marker):
    assert source.count(marker) == 1, 'The agent placement boundary changed: ' + marker
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 0
    for at in range(opening, len(source)):
        if source[at] == '{':
            depth += 1
        elif source[at] == '}':
            depth -= 1
            if depth == 0:
                return source[start:at + 1]
    raise AssertionError('Unclosed agent placement method: ' + marker)

methods = '\n\n'.join(method(marker) for marker in [
    '    func start(_ kind: AgentKind,',
    '    private func launch(_ kind: AgentKind,',
    '    private func startTracked(_ kind: AgentKind,'
])
# The last-agent preference is an inert record in this fixture; placement logic stays unchanged.
preference = 'UserDefaults.standard.set(kind.rawValue, forKey: "agentKind")'
assert methods.count(preference) == 1, 'The last-agent preference boundary changed'
methods = methods.replace(preference, 'lastAgent = kind.rawValue')
fixture = (root / 'Tools/fixtures/AgentPlacementTests.swift').read_text()
assert fixture.count('    /* AGENT_PLACEMENT_METHODS */') == 1
(target / 'AgentPlacementTests.swift').write_text(fixture.replace('    /* AGENT_PLACEMENT_METHODS */', methods))
PY
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos15.0" \
    -module-cache-path "$TASK_TMP/module-cache" "$TASK_TMP/AgentPlacementTests.swift" \
    -o "$TASK_TMP/AgentPlacementTests"
"$TASK_TMP/AgentPlacementTests" "$TASK_TMP/runtime"
