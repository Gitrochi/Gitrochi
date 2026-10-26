#!/usr/bin/env bash
# 실제 변경 파일 행으로 400·1000개 목록을 표시해 보이는 행만 생성하는지 확인한다. Git·계정·사용자 설정은 건드리지 않는다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import SwiftUI
import AppKit
import Observation

typealias ViewState<Value> = SwiftUI.State<Value>
enum ChangeKind { case untracked }
struct FileChange: Identifiable, Hashable {
    let path: String
    var oldPath: String? = nil
    var kind: ChangeKind = .untracked
    var staged = false
    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}
struct LineStat { var added: Int?; var deleted: Int? }
@Observable final class RepoStore {
    func revealInFinder(path: String) {}
    func copy(_ text: String) {}
}
struct StatusBadge: View { let kind: ChangeKind; var body: some View { Text("N").font(.caption).frame(width:16,height:16).background(.green) } }
struct LineStatText: View { let added: Int; let deleted: Int; var body: some View { Text("+\(added) −\(deleted)") } }

SWIFT
python3 - "$ROOT/Sources/Views/Shared/Theme.swift" "$TASK_TMP/main.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
row = source[source.index("struct FileRow: View {"):source.index("/// SwiftUI.State")]
with Path(sys.argv[2]).open("a") as output:
    output.write(row + "\n")
PYTHON
cat >> "$TASK_TMP/main.swift" <<'SWIFT'
@MainActor final class Counter { var count=0 }
struct Fixture: View {
 let files:[FileChange];let counter:Counter
 var body: some View {
  ScrollView {
   VStack(alignment:.leading,spacing:12) {
    Text("Changed files").font(.headline)
    VStack(alignment:.leading,spacing:4) {
     Text("Unstaged files").font(.headline)
     ChangeList(changes:files,isSelected:{_ in counter.count+=1; return false},actionIcon:"plus.circle",onOpen:{_ in}) { _ in Button("Stage") {} }
    }
    Text("Review staged changes")
   }.padding(12)
  }
 }
}
@main struct NativeChangesFixture {
 @MainActor static func main() {
  let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
  var results:[[String:Any]]=[]
  let suite="dev.gitrochi.changes-performance."+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!
  defer { defaults.removePersistentDomain(forName:suite) }
  for count in [400,1000] {
   let files=(0..<count).map{FileChange(path:"src/folder-\($0/20)/untracked-\($0).swift")}
   let counter=Counter(),store=RepoStore()
   let start=ContinuousClock.now
   let host=NSHostingView(rootView:Fixture(files:files,counter:counter).environment(store).defaultAppStorage(defaults))
   let window=NSWindow(contentRect:NSRect(x:-4000,y:0,width:340,height:650),styleMask:[.borderless],backing:.buffered,defer:false)
   window.contentView=host;window.orderBack(nil)
   host.frame=NSRect(x:0,y:0,width:340,height:650)
   host.layoutSubtreeIfNeeded();window.displayIfNeeded()
   let initial=ContinuousClock.now-start
   RunLoop.current.run(until:Date().addingTimeInterval(0.08))
   host.layoutSubtreeIfNeeded()
   let duration=ContinuousClock.now-start
   precondition(counter.count > 0 && counter.count < 120, "Large Changes lists must create only nearby rows")
   results.append(["files":count,"evaluatedRows":counter.count,"initialLayout":String(describing:initial),"withDisplay":String(describing:duration)])
   window.orderOut(nil)
  }
  let data=try! JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]);print(String(data:data,encoding:.utf8)!)
 }
}
SWIFT
xcrun swiftc -parse-as-library -O "$TASK_TMP/main.swift" "$ROOT/Sources/Views/Inspector/FileTree.swift" "$ROOT/Sources/Views/Shared/StudioStyle.swift" -o "$TASK_TMP/large-changes"
"$TASK_TMP/large-changes"
