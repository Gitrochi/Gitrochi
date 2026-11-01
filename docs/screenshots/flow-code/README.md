# Code-first flow authoring

Native macOS snapshots of the production `FlowEditorSheet`, `FlowCodeAuthoringView` and `FlowVisualEditor`, with the current bundled `gitch-flow` engine and a marked, isolated Git worktree. All text and file contents are synthetic. No flow, shell script, trust approval or network job is started.

| State | Light | Dark |
| --- | --- | --- |
| Full editor, code and live diagram | [Open](flow-code-wide-light.png) | [Open](flow-code-wide-dark.png) |
| Compact code and diagram | [Open](flow-code-compact-light.png) | [Open](flow-code-compact-dark.png) |
| Invalid source with an explicitly stale preview | [Open](flow-code-invalid-light.png) | [Open](flow-code-invalid-dark.png) |
| Related script with an unsaved native editor draft | [Open](flow-code-related-file-light.png) | [Open](flow-code-related-file-dark.png) |
| Optional module input forms and dependencies | [Open](flow-code-modules-light.png) | [Open](flow-code-modules-dark.png) |

The fixture checks recognized labels, parsing through the real CLI, fork/join dependencies, and native `NSTextView` typing into the independent related-file draft. It verifies that source bytes, isolated trust metadata and this worktree's real run directory remain unchanged. These captures do not establish Windows desktop behavior.

## Windows production components

These images render the production flow editor and related-file components in a browser on macOS. A local bridge calls the real `gitch-flow` design inspection, rendering and source-file APIs against isolated synthetic data. The conflict capture retains the draft after another writer changes the file. No flow, trust approval or credential change is performed by the visual checks; these are component previews, not Windows desktop screenshots.

| State | Light | Dark |
| --- | --- | --- |
| Wide code and live diagram | [Open](windows-code-light.png) | [Open](windows-code-dark.png) |
| Related-file conflict retaining the draft | — | [Open](windows-related-conflict-dark.png) |
| Narrow code and diagram, 620 px | [Open](windows-narrow-620-light.jpg) | [Open](windows-narrow-620-dark.jpg) |
| Narrow code and diagram, 360 px | [Open](windows-narrow-360-light.jpg) | [Open](windows-narrow-360-dark.jpg) |

At an 820 px viewport height, invalid-source checks retain positive editor/graph heights at both narrow widths (620 px: 228/135.5 px; 360 px: 207.5/116 px). The stale four-node diagram remains visible, Fit/Reset controls fit and respond, and the dependency counts remain readable. The browser draft is restored without saving or running a flow.

## Reproduce native captures

After building the macOS app, create a fresh worktree dedicated to screenshots, mark it, and run:

```sh
gitch wt new feature/flow-layout-capture ../flow-layout-fixture
printf 'flow-layout-fixture\n' > ../flow-layout-fixture/.gitrochi-flow-layout-fixture
macos/Tools/test-flow-layout.sh /tmp/flow-layout-shots ../flow-layout-fixture
```

The marker is required because the fixture replaces `.gitch/flow.yml` and `scripts/check.sh` inside that dedicated worktree. The app and engine run from a temporary fixture bundle, with an isolated settings folder; the user's Gitrochi app is left alone.
