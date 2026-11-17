#!/usr/bin/env bash
# The graph's fixed palettes as both appearances resolve them: the board's lanes and people, the derived dark set, the
# white gap between a node and a lane ring of nearly its colour, and the person an e-mail is drawn as. Windows checks
# the same values in windows/tests/palette.test.ts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
python3 - "$ROOT" "$TASK_TMP" <<'PY'
from pathlib import Path
import sys
root, target = map(Path, sys.argv[1:])
s = (root / 'Sources/Views/Shared/Theme.swift').read_text()
a = s.index('enum Palette {'); b = s.index('enum Fmt {', a)
(target / 'Palette.swift').write_text('import SwiftUI\n' + s[a:b])
PY
cat > "$TASK_TMP/main.swift" <<'SWIFT'
import AppKit
import SwiftUI

/// A colour as an appearance resolves it, as #rrggbb (and its alpha)
func resolve(_ color: Color, dark: Bool) -> (hex: String, alpha: CGFloat) {
    var result = ("", CGFloat(0))
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        let c = NSColor(color).usingColorSpace(.sRGB)!
        result = (String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                         Int((c.blueComponent * 255).rounded())), c.alphaComponent)
    }
    return result
}

func expect(_ actual: [String], _ expected: [String], _ what: String) {
    guard actual == expected else { FileHandle.standardError.write("\(what): \(actual) != \(expected)\n".data(using: .utf8)!); exit(1) }
}

let lines = (light: ["#1f5a9e", "#1f7a7a", "#a3560f", "#5f6b12", "#2b6d8f", "#5c6068", "#6b4f2a"],
             dark: ["#66a1eb", "#5baeae", "#da884b", "#99a755", "#67a7cc", "#9a9ea6", "#b89872"])
let tints = (light: ["#eaf0fa", "#e7f4f4", "#f9ece0", "#f0f2e0", "#e6f0f5", "#eeeff1", "#f3ede5"],
             dark: ["#1f2c3d", "#193030", "#39271a", "#2a2e19", "#1c2e38", "#2a2b2f", "#322a1f"])
let fills = (light: ["#e6e8fa", "#e0f1ec", "#e8eaed", "#f7e4eb"], dark: ["#2c3054", "#113c33", "#30343a", "#4b2636"])
let letters = (light: ["#3f4bb8", "#1f6b52", "#3a3f47", "#9b3a5f"], dark: ["#b4bbff", "#a5ccbb", "#bec1c7", "#ebadc0"])
let nodes = ["#4f5bd5", "#2a7d5f", "#4b5563", "#b4466e"]

for dark in [false, true] {
    let theme = dark ? "dark" : "light"
    expect(Palette.lanes.map { resolve($0.line, dark: dark).hex }, dark ? lines.dark : lines.light, "\(theme) lane lines")
    expect(Palette.lanes.map { resolve($0.tint, dark: dark).hex }, dark ? tints.dark : tints.light, "\(theme) lane tints")
    // a filled chip: white in light, the lane's own tint in dark
    expect(Palette.lanes.map { resolve($0.onLine, dark: dark).hex }, dark ? tints.dark : tints.light.map { _ in "#ffffff" }, "\(theme) text on a filled chip")
    expect(Palette.lanes.map { String(format: "%.2f", resolve($0.selected, dark: dark).alpha) }, Array(repeating: "0.35", count: 7), "\(theme) selected band")
    expect(Palette.people.map { resolve($0.fill, dark: dark).hex }, dark ? fills.dark : fills.light, "\(theme) avatar fills")
    expect(Palette.people.map { resolve($0.letter, dark: dark).hex }, dark ? letters.dark : letters.light, "\(theme) avatar letters")
    expect(Palette.people.map { resolve($0.node, dark: dark).hex }, nodes, "\(theme) node colours")
    // the 2pt surface gap: Sam's green on the teal lane and Morgan's slate on the grey one, in light only
    let gaps = (0..<4).flatMap { person in (0..<7).map { resolve(Palette.nodeGap(person: person, lane: $0), dark: dark).alpha > 0 ? "\(person):\($0)" : nil } }.compactMap { $0 }
    expect(gaps, dark ? [] : ["1:1", "2:5"], "\(theme) node gaps")
}
expect([resolve(Palette.nodeGap(person: 1, lane: 1), dark: false).hex], ["#ffffff"], "the gap is the surface")
expect([7, -1, 9].map { resolve(Palette.lane($0).line, dark: false).hex }, [lines.light[0], lines.light[6], lines.light[2]], "lanes wrap round the palette")
// pinned: windows/tests/palette.test.ts checks the same addresses
let emails = ["alex@example.com", "sam@example.com", "morgan@example.com", "jordan@example.com", "demo-alex", "look-1", "look-2", "look-3"]
expect(emails.map { String(Palette.personIndex($0)) }, ["0", "3", "2", "0", "1", "0", "1", "2"], "the person an e-mail is drawn as")
expect([String(Palette.personIndex("Alex@Example.COM"))], ["0"], "an e-mail in any case")
print("Graph palettes: lanes, tints and filled-chip text in both appearances, people, the node gap and the e-mail mapping")
SWIFT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos15.0" "$TASK_TMP/Palette.swift" "$TASK_TMP/main.swift" -o "$TASK_TMP/graph-palette"
"$TASK_TMP/graph-palette"
