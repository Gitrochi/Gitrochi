#!/usr/bin/env bash
# Render the production Projects workspace with isolated, synthetic account and project data.
# Set GITROCHI_PROJECT_LAYOUT_LOCAL_ONLY=1 to skip remote project and schedule scenarios.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'if [[ -z "${GITROCHI_PROJECT_LAYOUT_KEEP_SOURCES:-}" ]]; then rm -rf "$TASK_TMP"; else echo "Fixture sources retained: $TASK_TMP" >&2; fi' EXIT
TASK_OUTPUT="${1:-$TASK_TMP/output}"
mkdir -p "$TASK_OUTPUT"
ARCH="$(uname -m)"
ST="$ROOT/.build/swiftterm/$ARCH"
if [[ ! -f "$ST/libSwiftTerm.a" ]]; then
    echo "SwiftTerm build is missing; run macos/build.sh first." >&2
    exit 1
fi
python3 - "$ROOT" "$TASK_TMP" <<'PY'
from pathlib import Path
import sys

root, target = map(Path, sys.argv[1:])

def replace_once(text, needle, replacement, label):
    assert text.count(needle) == 1, label + ' changed'
    return text.replace(needle, replacement)

for source in (root / 'Sources').rglob('*.swift'):
    relative = source.relative_to(root / 'Sources').as_posix()
    text = source.read_text().replace('UserDefaults.standard', 'projectFixtureDefaults')
    text = text.replace('defaults: UserDefaults = .standard', 'defaults: UserDefaults = projectFixtureDefaults')
    if relative == 'App/App.swift':
        start = text.index('@main\nstruct GitrochiApp: App {')
        end = text.index('/// 창(탭) 하나 = 저장소 하나', start)
        text = text[:start] + text[end:]
    elif relative == 'Services/Accounts.swift':
        text = replace_once(text, 'private let credentials = CredentialCache { await Keychain.read($0) }',
                            'private let credentials = CredentialCache { _ in ProjectFixtureCredentialCounter.read() }',
                            'Account credential reader')
        text = text.replace('        Askpass.install()', '        // Rendering never installs a credential helper.')
        text += '\nextension AccountStore { func fixtureClearAccounts() { accounts = []; revision += 1 }; func fixtureSetAccounts(_ values: [HostAccount]) { accounts = values; revision += 1 } }\n'
    elif relative == 'Services/LocalProjects.swift':
        text = replace_once(text, 'static let shared = LocalProjectStore()',
                            'static let shared = LocalProjectStore(storage: LocalProjectFileStorage(url: projectFixtureLocalStorageURL))',
                            'Local planner storage must stay inside the fixture output folder')
    elif relative == 'Services/Tools.swift':
        start = text.index('    private init() {', text.index('final class ToolStore'))
        end = text.index('\n    func detect(', start)
        text = text[:start] + '''    private init() {
        states[.git] = State(path: "/usr/bin/git", source: .auto, version: "fixture")
    }
''' + text[end:]
    elif relative == 'Views/Hub/ProjectWorkspace.swift':
        text = replace_once(text, '@ViewState private var layout = "overview"',
                            '@ViewState private var layout = "board"',
                            'Board-only layout fixture starts from its explicit scenario')
        text = replace_once(text, '.background(Color(nsColor: .windowBackgroundColor))',
                            '.background(Color(nsColor: .windowBackgroundColor)).background(ProjectWorkspaceProbe(identifier: "schedule-settings:" + scheduleSettings.completedOptionIDs.sorted().joined(separator: ","))).background(ProjectWorkspaceProbe(identifier: fixtureScheduleStamp)).background(ProjectWorkspaceProbe(identifier: "selected-project-row:" + (selectedID ?? "none")))',
                            'Preloaded project restores its saved schedule settings')
        text += '''
extension ProjectWorkspace {
    fileprivate var fixtureScheduleStamp: String {
        let resolved = ProjectSchedule.fields(detail?.fields ?? [], settings: scheduleSettings)
        let summary = ProjectSchedule.summary(ProjectSchedule.entries(detail?.rows ?? [], fields: detail?.fields ?? [], settings: scheduleSettings), today: ProjectSchedule.today())
        return "schedule-config:" + (resolved.due?.id ?? "none") + ":" + summary.upcoming.formatted()
    }
}
'''
        text = replace_once(text, '            header\n            accessNotice',
                            '            header.background(ProjectWorkspaceProbe(identifier: "project-header"))\n            accessNotice',
                            'Project header measurement attachment')
        text = replace_once(text, '}.accessibilityLabel("Project board")',
                            '}.accessibilityLabel("Project board")\n                .background(ProjectWorkspaceProbe(identifier: "project-board"))',
                            'Project board measurement attachment')
        text = replace_once(text, '}.frame(maxWidth: .infinity, alignment: .leading).disabled(locked)',
                            '}.frame(maxWidth: .infinity, alignment: .leading).disabled(locked)\n            .background(ProjectWorkspaceProbe(identifier: "project-controls"))',
                            'Project controls measurement attachment')
    elif relative == 'Views/Hub/ProjectWorkspaceHeader.swift':
        text = replace_once(text, 'Button(action: addTask) { Label("New task", systemImage: "plus").fontWeight(.semibold) }.buttonStyle(.borderedProminent).controlSize(.large)',
                            'Button(action: addTask) { Label("New task", systemImage: "plus").fontWeight(.semibold) }.buttonStyle(.borderedProminent).controlSize(.large).background(ProjectWorkspaceProbe(identifier: "project-add-item"))',
                            'Local project add-task measurement attachment')
        text = replace_once(text, '.background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))',
                            '.background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8)).background(ProjectWorkspaceProbe(identifier: "project-add-item"))',
                            'Remote project add-item measurement attachment')
    elif relative == 'Views/Hub/ProjectTaskViews.swift':
        text = replace_once(text, '.task(id: row.id + store.hubContextStamp) { await readConversation() }',
                            '.task(id: row.id + store.hubContextStamp) { await readConversation() }.background(ProjectWorkspaceProbe(identifier: "project-inspector:" + row.id)).background(ProjectWorkspaceProbe(identifier: "inspector-comments:" + conversationComments.count.formatted())).background(ProjectWorkspaceProbe(identifier: "inspector-comment-text:" + commentText)).background(ProjectWorkspaceProbe(identifier: "inspector-comment-error:" + (commentError ?? "none"))).background(ProjectWorkspaceProbe(identifier: "inspector-comment-posted:" + String(commentPosted)))',
                            'Requested project task inspector measurement attachment')
        text = replace_once(text, '@ViewState private var adding = false',
                            '@ViewState private var adding = projectFixtureDefaults.bool(forKey: "quickAddFixtureOpen")',
                            'Quick-add fixture opens the actual inline form')
        text = replace_once(text, '.overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.3)))',
                            '.overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.3))).background(ProjectWorkspaceProbe(identifier: "quick-add-form:" + column.id)).background(ProjectWorkspaceProbe(identifier: "quick-add-title:" + title)).background(ProjectWorkspaceProbe(identifier: "quick-add-saving:" + String(creating))).background(ProjectWorkspaceProbe(identifier: "quick-add-error:" + (createError ?? "none")))',
                            'Quick-add form state measurement attachment')
        text = replace_once(text, '.menuStyle(.borderlessButton).menuIndicator(.hidden).disabled(!canEdit).accessibilityLabel(label)',
                            '.menuStyle(.borderlessButton).menuIndicator(.hidden).disabled(!canEdit).accessibilityLabel(label).background(ProjectWorkspaceProbe(identifier: "inspector-field:" + field.id + ":options:" + field.options.count.formatted()))',
                            'Inspector actual option-menu measurement attachment')
        text = replace_once(text, '.buttonStyle(.plain).disabled(!canEdit).accessibilityLabel(label)',
                            '.buttonStyle(.plain).disabled(!canEdit).accessibilityLabel(label).background(ProjectWorkspaceProbe(identifier: "inspector-field:" + field.id + ":sheet"))',
                            'Inspector actual date/text-editor measurement attachment')
        text = replace_once(text, '}.buttonStyle(.plain).accessibilityLabel(row.title)',
                            '}.buttonStyle(.plain).background(ProjectWorkspaceProbe(identifier: "task:" + row.id)).accessibilityLabel(row.title)',
                            'Project card measurement attachment')
        text = replace_once(text, '.overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.1)))',
                            '.overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.1)))\n        .background(ProjectWorkspaceProbe(identifier: "column:" + column.id))',
                            'Project column measurement attachment')
        text = replace_once(text, '.accessibilityLabel("Project table header")',
                            '.accessibilityLabel("Project table header").background(ProjectWorkspaceProbe(identifier: "project-table-header"))',
                            'Project table header measurement attachment')
        text = replace_once(text, '.accessibilityLabel("Project table")',
                            '.accessibilityLabel("Project table").background(ProjectWorkspaceProbe(identifier: "project-table"))',
                            'Project table measurement attachment')
        text = replace_once(text, '                                .accessibilityElement(children: .contain).accessibilityLabel(row.title)',
                            '                                .background(ProjectWorkspaceProbe(identifier: "table-row:" + row.id)).accessibilityElement(children: .contain).accessibilityLabel(row.title)',
                            'Project table row measurement attachment')
    elif relative == 'Views/Hub/ProjectRoadmap.swift':
        text = replace_once(text, '.accessibilityLabel("Project roadmap")',
                            '.accessibilityLabel("Project roadmap").background(ProjectWorkspaceProbe(identifier: "project-roadmap"))',
                            'Project roadmap measurement attachment')
        text = replace_once(text, '                    }.buttonStyle(.plain)\n                    Button {',
                            '                    }.buttonStyle(.plain).background(ProjectWorkspaceProbe(identifier: "roadmap-task:" + entry.id))\n                    Button {',
                            'Unscheduled roadmap task measurement attachment')
        text = replace_once(text, '.buttonStyle(.borderless).fixedSize().disabled(dateFields.isEmpty).help("Edit task date")',
                            '.buttonStyle(.borderless).fixedSize().disabled(dateFields.isEmpty).help("Edit task date").background(ProjectWorkspaceProbe(identifier: "roadmap-schedule:" + entry.id))',
                            'Unscheduled roadmap date action measurement attachment')
    elif relative == 'Views/Hub/ProjectItemEditors.swift':
        text = replace_once(text, '}.frame(width: 500).background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(saving)',
                            '}.frame(width: 500).background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(saving).background(ProjectWorkspaceProbe(identifier: "field-editor")).background(ProjectWorkspaceProbe(identifier: "field-editor-value:" + value)).background(ProjectWorkspaceProbe(identifier: "field-editor-error:" + (error ?? "none")))',
                            'Typed date editor state measurement attachment')
    elif relative == 'Views/Hub/ProjectActionReviewSheet.swift':
        text = replace_once(text, '}.frame(width: 540).background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(saving)',
                            '}.frame(width: 540).background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(saving).background(ProjectWorkspaceProbe(identifier: "action-review")).background(ProjectWorkspaceProbe(identifier: "action-review-error:" + (error ?? "none")))',
                            'Destructive project action review state measurement attachment')
    elif relative == 'Views/Hub/ProjectDashboard.swift':
        text = replace_once(text, '.accessibilityLabel("Project scheduling overview")',
                            '.accessibilityLabel("Project scheduling overview").background(ProjectWorkspaceProbe(identifier: "schedule-overview"))',
                            'Schedule overview measurement attachment')
    elif relative == 'Views/Hub/ProjectCalendar.swift':
        text = replace_once(text, '.accessibilityLabel("Project calendar")',
                            '.accessibilityLabel("Project calendar").background(ProjectWorkspaceProbe(identifier: "schedule-calendar"))',
                            'Schedule calendar measurement attachment')
        text = replace_once(text, '.dropDestination(for: String.self)',
                            '.background(ProjectWorkspaceProbe(identifier: "calendar-day:" + day)).dropDestination(for: String.self)',
                            'Calendar day measurement attachment')
    elif relative == 'Views/Workspace/WorkspacePlanningDashboard.swift':
        text = replace_once(text, '@ViewState private var mode = "agenda"',
                            '@ViewState private var mode = projectFixtureDefaults.string(forKey: "homeFixtureMode") ?? "agenda"',
                            'Home fixture selects its explicit production view scenario')
        text = replace_once(text, '.accessibilityLabel("Home planning dashboard")',
                            '.accessibilityLabel("Home planning dashboard").background(ProjectWorkspaceProbe(identifier: "schedule-home")).background(ProjectWorkspaceProbe(identifier: "home-project-count:" + data.projects.count.formatted())).background(ProjectWorkspaceProbe(identifier: "home-task-count:" + tasks.count.formatted())).background(ProjectWorkspaceProbe(identifier: "home-source:" + (isLocal ? "local" : "remote"))).background(ProjectWorkspaceProbe(identifier: "home-load-error:" + (data.error ?? "none"))).background(ProjectWorkspaceProbe(identifier: "home-context-ready:" + String(portfolioContext == context)))',
                            'Home planning measurement attachment')
        text = replace_once(text, '.frame(minHeight: 165, alignment: .top).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))',
                            '.frame(minHeight: 165, alignment: .top).background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)).background(ProjectWorkspaceProbe(identifier: "home-week:" + day))',
                            'Home week day measurement attachment')
        text = replace_once(text, '}.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))',
                            '}.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).background(ProjectWorkspaceProbe(identifier: "home-project:" + detail.item.id))',
                            'Home project card measurement attachment')
    dest = target / 'Sources' / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text)
PY
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$TASK_TMP/Sources" -name '*.swift' -print0)
TASK_CORE="$(CARGO_NET_OFFLINE=true bash "$ROOT/../tools/build-core-native.sh" "$ARCH")"
cp "$TASK_CORE" "$TASK_TMP/core.a"
cp "$ROOT/Tools/fixtures/ProjectWorkspaceLayout.swift" "$TASK_TMP/ProjectWorkspaceLayout.swift"
TASK_APP="$TASK_OUTPUT/ProjectWorkspaceLayoutFixture.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp -R "$ROOT/Resources/Localizations/"*.lproj "$TASK_APP/Contents/Resources/"
mkdir -p "$TASK_APP/Contents/Resources/en.lproj"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.gitrochi.project-workspace-fixture</string>
<key>CFBundleExecutable</key><string>ProjectWorkspaceLayout</string>
<key>CFBundleName</key><string>Gitrochi Project Workspace Fixture</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 5 -whole-module-optimization -Onone -target "$ARCH-apple-macos15.0" \
    -I "$ST" -I "$ROOT/../crates/gitrochi-core/include" -L "$ST" -lSwiftTerm \
    "${SOURCES[@]}" "$TASK_TMP/ProjectWorkspaceLayout.swift" "$TASK_TMP/core.a" \
    -o "$TASK_APP/Contents/MacOS/ProjectWorkspaceLayout"
GITROCHI_PROJECT_LAYOUT_LANGUAGE=en "$TASK_APP/Contents/MacOS/ProjectWorkspaceLayout" "$TASK_OUTPUT" -AppleLanguages '(en)'
GITROCHI_PROJECT_LAYOUT_LANGUAGE=ko "$TASK_APP/Contents/MacOS/ProjectWorkspaceLayout" "$TASK_OUTPUT" -AppleLanguages '(ko)'
python3 - "$TASK_OUTPUT" <<'PY'
from pathlib import Path
import json
import sys

output = Path(sys.argv[1])
result = json.loads((output / 'result-en.json').read_text())
translated = json.loads((output / 'result-ko.json').read_text())
assert result['ok'] and translated['ok']
assert result['networkRequests'] == translated['networkRequests'] == 0
result['checks'] += translated['checks']
result['languages'] = [result.pop('language'), translated['language']]
assert len(result['checks']) == (54 if result['localOnly'] else 104)
assert len({check['scenario'] for check in result['checks']}) == len(result['checks'])
(output / 'result.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
print('Validated ' + str(len(result['checks'])) + ' native project scenarios in English and Korean.')
PY
