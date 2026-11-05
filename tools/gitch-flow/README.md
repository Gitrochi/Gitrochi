# Flow engine

`gitch-flow` runs the repository's `.gitch/flow.yml` and serves the native apps' JSON contracts. The execution format and guards are described in [the flow design](../../docs/flow/DESIGN.md).

## Read-only visual authoring

The apps use one shared YAML implementation. Neither `inspect` nor `render` requires a Git repository, reads a source path, writes files, approves trust, accesses connections, nor executes source code.

Pass one JSON object on stdin:

```text
gitch-flow design inspect --json
{"yaml":"version: 1\nflows: {}\n","fileName":".gitch/flow.yml"}

gitch-flow design render --json
{"document":{"version":1,"flows":{}},"originalYaml":"version: 1\nflows: {}\n"}
```

`fileName` is an optional label for recognizing dropped sources. It is never opened. Requests are limited to 4 MiB, YAML sources to 2 MiB and visual trees to 64 nesting levels.

Inspection returns:

```json
{
  "schemaVersion": 1,
  "document": {"version": 1, "flows": {}},
  "yaml": "version: 1\nflows: {}\n",
  "format": "flow",
  "diagnostics": [],
  "editable": true,
  "proposal": null
}
```

`document` contains every parsed field, including advanced or unknown fields. A visual editor must retain this complete tree and change only the selected fields. `editable` is true for native flow sources that the strict parser can safely represent. Anchors, aliases, tags, duplicate keys, multiple documents and non-mapping roots produce diagnostics and stay read-only. Integers beyond the apps' exact numeric range (plus or minus 9007199254740991) also stay source-only with `NUMERIC_PRECISION`; changed rendering is refused to prevent rounding. The strict parser consumes events iteratively and refuses nesting beyond 128 levels before building an unbounded tree.

Recognized formats are `flow`, `github`, `gitlab`, `compose`, `jenkins` and `unknown`. GitHub Actions and GitLab YAML remain complete source mappings. Jenkins Groovy is retained as source text and is never evaluated. External CI proposals contain a separate native flow that dispatches the original workflow or job through `ci.github.workflow`, `ci.gitlab.pipeline` or `ci.jenkins.job`. They deliberately leave the connection empty for explicit configuration. Conditions, deployment guards, Actions, plugins, runner settings and expressions stay in the original provider; local shell extraction is not attempted. Compose service dependencies can be previewed, but startup and deployment require explicitly selecting the actual source file and configuring the appropriate Docker service or deployment.

Rendering returns `schemaVersion`, `yaml`, `diagnostics` and `formattingChanged`. If `originalYaml` parses to the supplied document, the original bytes, comments, quoting and line endings are returned exactly. A visual change emits the entire edited tree and verifies it with the execution parser. It reports `FORMAT_NORMALIZED`: formatting is normalized and comments are removed. Review that source before saving. Unsupported original YAML is never silently normalized.

Diagnostics have `severity` (`error`, `warning` or `info`), `code`, `message` and optional `path`/`line`. Source diagnostics return exit code 0 so apps can show the structured response. Invalid JSON transport or unsupported CLI options return exit code 1. A rendering error returns an empty `yaml`; callers must not save it. Saving and engine validation remain separate operations, and changed flow files still require the existing trust review before running.

The contracts are available through:

```text
gitch-flow schema flow-design-inspect
gitch-flow schema flow-design-render
```

The existing `blocks --json` and `block <id> --json` commands provide block categories, capabilities, outward/destructive flags and input JSON Schemas for module forms.

## Related source files

`design source --json` operates on one explicitly selected file in the current Git repository. It does not discover scripts or interpret their content. Pass one JSON object on stdin:

```json
{"operation":"read","path":"scripts/check.sh"}
```

An opened file returns its exact `content` and SHA-256 byte `fingerprint`:

```json
{"schemaVersion":1,"path":"scripts/check.sh","content":"echo example\n","fingerprint":"...64 lowercase hex digits...","exists":true,"saved":false,"diagnostics":[]}
```

Save with `{"operation":"write","path":"scripts/check.sh","content":"edited text\n","expected":"<fingerprint from read>"}`. The engine checks the fingerprint before preparing a temporary replacement and again immediately before the atomic replacement. A changed or deleted file returns `SOURCE_CONFLICT`; the app must keep the draft and ask the user to reopen the file. This is optimistic conflict detection followed by atomic replacement, not an operating-system atomic compare-and-swap against arbitrary simultaneous writers. Unix also checks the pinned parent directory identity before committing. New files require explicit `"expected":null` and are created exclusively; an existing file is never replaced by a create request. Parent folders must already exist unless that new-file request also explicitly supplies `"createParents":true`. Only exclusive new-file writes accept that option, which creates missing parents under the same path/link checks. Reads and existing-file saves never create directories. A failed create may leave newly created empty folders; existing folders and their permissions are preserved.

Files must be regular UTF-8 text without NUL bytes, at most 2 MiB. Requests allow up to 16 MiB so JSON escaping does not reduce the text limit. UTF-8 BOMs and CRLF line endings remain in the returned content and fingerprint. Byte-identical saves do not replace the file or change its modification time. Existing Unix mode bits and macOS extended/Linux POSIX access ACLs are copied to the empty replacement before source bytes are written. Windows copies the source DACL before writing, then commits with `ReplaceFileW` without ignoring metadata errors. The replacement must already have the same owner (and group on Unix); saves do not change ownership or request privileges. New files inherit their selected parent's normal access settings. Changed existing saves fail with `SOURCE_METADATA` if access metadata cannot be preserved, including mismatched ownership, unsupported NFS4 ACLs or platforms without an access-control implementation. Paths use relative forward slashes. Traversal, absolute paths, Windows path aliases, any case-insensitive `.git` component, symbolic links and Windows reparse points are rejected.

Windows replacement uses a protected recovery backup because some filesystem errors can move the old name before failing. A missing original name is restored exclusively. If restoration or recovery cleanup cannot finish, `SOURCE_RECOVERY` identifies the retained original copy in its diagnostic `path`; callers retain their draft and must reopen the file. The final source may already contain the new bytes when only backup cleanup failed. Recovery copies are never discarded to force a save through.

Successful saves return `saved:true`, the saved content and its new fingerprint. Source errors return exit status 0 with `content:null`, `fingerprint:null`, `saved:false` and an error diagnostic. `exists` means a file was successfully opened or saved; it is false on errors, including conflicts. `SOURCE_NOT_FOUND` identifies a missing selected file and `SOURCE_PARENT_NOT_FOUND` a missing parent folder. An explicit New file action may use either to prepare a draft; other failures must not be treated as permission to create. Malformed JSON or unsupported CLI flags return exit status 1. Callers must check the payload, not just the exit status, and retain an unsaved draft after any error. No source operation approves trust or runs a script.

The schema is available as `gitch-flow schema flow-design-source` (alias `design-source`).

## Checks

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test --locked
```

`tests/design.rs` covers exact no-op preservation, full-tree edits, expressions, unusual scalars, external CI proposals, unsupported YAML, mutation-option rejection and the stdin transport.
`tests/design_source.rs` covers byte preservation, fingerprint conflicts, exclusive creation, bounded strict text, path and link rejection, Unix mode/macOS ACL preservation, and editing without execution. Windows CI additionally runs `tests/design_source_windows.rs` against a protected owner-only DACL.
