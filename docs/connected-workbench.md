# Connected analysis and work validation

Gitrochi connects the current selection to repository questions, structure graphs, configured verification flows, local planning and deliberate handoffs. Existing Git, graph, Flow, agent and team hub services remain responsible for their own results.

## Where to start

- Use the **Structure graph workspace** toolbar button to inspect an embedded, offline graph. Its coverage panel records the revision, scope, tool version, graph identity and analysis limits. Refresh after editing files; a snapshot is evidence from a point in time.
- Open **Repository assistant** from the repository menu. Choose a task, inspect the selection context, and explicitly send the question. Task prompts can be edited, saved per repository and reset. Loading graph context reads local repository data and does not call an AI provider.
- Open **Work validation** from the repository menu or staged impact analysis. Verification, team overlap evidence and agent handoffs share one place. Test candidates are suggestions, not execution or coverage claims.
- In a local project's task inspector, edit **Task predecessors** and optional whole-day duration estimates. The Roadmap includes a focused predecessor → selected task → successor view, ready/blocked states, and a critical path only when every required duration is explicit.

## Capability map

| Area | Implementation |
| --- | --- |
| Selected screen context | Versioned context includes anonymized repository identity, HEAD, selected revision, scope, paths, graph nodes, observation time and a stable fingerprint. Selection or repository changes invalidate the conversation context. |
| Assistant graph actions | A bounded, typed envelope permits node selection, directed-path selection and clear only. Both the assistant boundary and graph document validate the actual snapshot and known node IDs. Applying a selection is an explicit action. |
| Screen-to-code map | Maintained entries connect Gitrochi screens to macOS and Windows implementations and verification files. They are labeled maintained links, rather than inferred imports. Source links require the Gitrochi source checkout. |
| Graph evidence | Full revision, scope, source graph identity, tool version, coverage, inferred edges and unsupported analysis are included in graph data and reports. Filtered/omitted relationships are not evidence of absence. |
| Reusable prompts | Structure, impact, review, tests and performance starters include the current selection. Saving a template does not freeze an old generated context footer or send a question. |
| Graph workspace | Both apps reuse the existing offline graph document. Windows embeds a sandboxed frame; macOS uses a bounded WebKit window. Network access is blocked and app links are limited to validated repository-relative destinations. External-browser use remains available. |
| Execution evidence | Configured, trusted local flows can bind a run to before/after tracked-working-content stamps and actual engine records. Other plans use the existing Flows review path. Counts come only from reported test observations. |
| Large graphs | Reproducible 2,000/10,000/50,000-node renderer workloads measure preparation, selection, snapshot projection and heap usage. Repeated immutable snapshot projections are cached. See the measurement limits below. |
| Accessible graph navigation | Node lists and relationship lists expose native controls, keyboard traversal and text evidence alongside the visual graph. Physical screen-reader verification remains separate. |
| Environment validation | Windows selftest includes native spaces/Unicode/nested-path I/O, system Git parsing, and disconnected hub reads. Device installation, WSL and real-server authentication scenarios remain explicitly environment-specific. |
| Project dependency planning | Local task predecessors reject self links, duplicates, missing targets and cycles. Deleting a referenced predecessor requires removing its links first. Incomplete archived predecessors remain blockers. Saving dependencies does not change task dates. |
| Team overlap evidence | Explicitly configured hub reads use the existing v1 presence/overlap API, secure credential storage, bounded responses and no redirects. The UI refreshes snapshots every 30 seconds, distinguishes observations from related-file inferences, rejects mismatched participants, and preserves stale data visibly on disconnection. Overlap paths can be highlighted in the graph. |
| Agent handoff | Existing tracked sessions can be assigned a task ID, goal, relative-path boundaries and remaining work. Overlapping declarations are reported without attributing file authorship or stopping sessions. Captured handoffs contain revision-bound evidence and redact secret/local-path patterns. |
| Reproducible reports | Graph exports retain graph provenance and explicit tests-not-run information. Handoff JSON separately records actual Flow observations, content stamp, candidate paths and limits. User task text can contain private information and should be reviewed before sharing. |

## Verification semantics

The working-content stamp hashes the full HEAD identity, tracked working diff and machine-readable status locally. An unborn repository also includes staged and unstaged changes. Untracked bytes, assume-unchanged/skip-worktree entries and dirty submodules prevent a certified current result. No repository contents or local paths are sent to the hub by this view.

A current result requires a known terminal Flow state, an actual completion time, matching run ID and revision, and equal before/after/current stamps. Missing end observations and historical runs without bindings remain unbound. Changing the observed repository state clears current evidence immediately while the next snapshot is read. An unchanged before/after stamp does not freeze the repository during execution, and a passing Flow does not prove every suggested test ran.

The local planning format accepts older documents without predecessor/duration fields. Current clients preserve those fields in other edits. Older app versions may discard unknown optional metadata when saving; do not edit dependency plans through an older client if preservation is required. Dependency planning is local; provider-backed project items are not silently rewritten.

## Reproduce checks

```sh
macos/build.sh
bash macos/Tools/test-work-context.sh
bash macos/Tools/test-work-validation.sh
bash macos/Tools/test-structure-graph.sh
bash macos/Tools/test-project-dependencies.sh
bash macos/Tools/test-local-projects.sh
node --test tools/gitrochi-mcp/server.test.mjs
node --test tools/gitch/tests/graph_actions.test.mjs
bash tools/gitch/tests/run.sh
```

From `windows/`, run `npm run build`, `npm test` and `cargo check --manifest-path src-tauri/Cargo.toml`. Native network boundary unit tests are `cargo test --manifest-path src-tauri/Cargo.toml net::ci_log_tests`. The actual-app selftest registers assistant context, embedded graphs, project dependencies, work validation and native environment paths; fixture tests do not assert that a physical Windows installation or production server was exercised.

## Renderer measurements

Run `node tools/gitch/tests/graph_scale_benchmark.mjs <chromium-executable> <output-directory>`. The script creates synthetic static TypeScript nodes, 40 files per folder, a sparse set of cross-folder imports, and standalone graph/review documents. It is a renderer benchmark, not a parser/index benchmark or a product service-level objective. Raw timestamps have browser timer resolution and normal run-to-run noise.

Observed on an Apple M5 Pro, arm64 macOS, Node 22.23.3, with the pack layout:

| Nodes | Edges | Renderer ready, after (ms) | First selected node (ms) | Later selected nodes (ms) | JS heap, after (MiB) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 2,000 | 2,048 | 32.5 | 3.5 | 0.4–0.6 | 20.0 |
| 10,000 | 10,248 | 96.9 | 10.6 | 1.0–1.7 | 73.0 |
| 50,000 | 51,248 | 436.9 | 86.3 | 4.0–5.1 | 288.0 |

At 50,000 nodes, caching the immutable snapshot projection changed repeated inspection from 0.6–1.4 ms to 0–0.1 ms over five samples, while the first projection changed from approximately 1.9 ms to 2.8 ms. Zero means below this timer's resolution, not zero work. The first selection and large-document heap costs still need attention for denser repositories. The measured runs reported no renderer errors or external requests. Re-run on Windows hardware before choosing a cross-platform performance target.

## Remaining environment checks

- VoiceOver and Narrator sessions with users of those tools, including high contrast and reduced motion.
- Physical Windows installer/update smoke checks, long-path policy configurations, Git Bash/PowerShell/WSL combinations and credential cancellation.
- Configured GitHub/GitLab sandbox writes and LFS locking. Local mocks and read-only repository checks do not establish real-server behavior.
- Team presence is read through periodic snapshots, rather than a persistent SSE subscription. The monitor remains the service that publishes presence.
