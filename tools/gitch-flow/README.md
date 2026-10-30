# Flow engine

`gitch-flow` runs the repository's `.gitch/flow.yml` and serves the native apps' JSON contracts. The execution format and guards are described in [the flow design](../../docs/flow/DESIGN.md).

## Read-only visual authoring

The apps use one shared YAML implementation. Neither authoring command requires a Git repository, reads a source path, writes files, approves trust, accesses connections, nor executes source code.

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

## Checks

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test --locked
```

`tests/design.rs` covers exact no-op preservation, full-tree edits, expressions, unusual scalars, external CI proposals, unsupported YAML, mutation-option rejection and the stdin transport.
