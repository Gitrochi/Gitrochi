#!/usr/bin/env python3
"""Regenerate the "Shared Rust core dependency notices" section of THIRD_PARTY_NOTICES.md.

The section covers the locked normal and build dependencies of the crates/ workspace (the
shared core and the repository index) on every platform the apps ship, with each upstream
license file reproduced once per identical text. `--check` fails when the file is out of date.
"""

import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
HEADING = "## Shared Rust core dependency notices"
# macOS (both architectures), Windows, Linux helpers and the WebAssembly core.
TARGETS = [
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
    "x86_64-pc-windows-msvc",
    "x86_64-unknown-linux-gnu",
    "wasm32-unknown-unknown",
]
INTRO = (
    "The shared native and WebAssembly core and the repository index use the following "
    "Cargo.lock dependencies. These upstream notices are distributed with both application "
    "bundles through this file. This inventory covers the `crates/` workspace "
    "(`tools/generate-core-notices.py` regenerates it); the audit status of other dependencies "
    "above is unchanged. The Windows app resolves the same crates through its own lockfile."
)
SQLITE = (
    "`libsqlite3-sys` compiles in the SQLite amalgamation it bundles. SQLite is in the public "
    "domain ([sqlite.org/copyright](https://sqlite.org/copyright.html)); it needs no notice, and "
    "none is added here. Gitrochi's C++ tokenizer in `native/` is Gitrochi's own code."
)


def metadata(target):
    output = subprocess.run(
        [
            "cargo", "metadata", "--format-version", "1", "--locked",
            "--manifest-path", str(ROOT / "crates" / "Cargo.toml"), "--filter-platform", target,
        ],
        check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(output)


def packages():
    """Every normal/build dependency reachable from the workspace members on some target."""
    found = {}
    for target in TARGETS:
        data = metadata(target)
        nodes = {node["id"]: node for node in data["resolve"]["nodes"]}
        members = set(data["workspace_members"])
        seen = set(members)
        pending = list(members)
        while pending:
            for dependency in nodes[pending.pop()]["deps"]:
                if not any(kind["kind"] in (None, "build") for kind in dependency["dep_kinds"]):
                    continue
                if dependency["pkg"] not in seen:
                    seen.add(dependency["pkg"])
                    pending.append(dependency["pkg"])
        for package in data["packages"]:
            if package["id"] in seen - members:
                if package["source"] != "registry+https://github.com/rust-lang/crates.io-index":
                    raise ValueError(f"Unreviewed dependency source: {package['name']} {package['version']}")
                found[package["id"]] = package
    return sorted(found.values(), key=lambda p: (p["name"], p["version"]))


def license_files(package):
    directory = Path(package["manifest_path"]).parent
    names = [
        path for path in directory.iterdir()
        if path.is_file() and path.name.upper().startswith(("LICENSE", "COPYING", "NOTICE", "COPYRIGHT"))
    ]
    if not names:
        raise ValueError(f"No license file in {package['name']} {package['version']}")
    return sorted(names, key=lambda path: path.name)


def render(listed):
    lines = [HEADING, "", INTRO, "", "| Package | Version | Manifest license | Upstream |", "|---|---|---|---|"]
    for package in listed:
        upstream = package.get("repository") or f"https://crates.io/crates/{package['name']}"
        lines.append(
            f"| {package['name']} | {package['version']} | `{package.get('license') or 'see files'}` "
            f"| [source]({upstream}) |"
        )
    lines += ["", SQLITE, ""]
    groups = {}
    for package in listed:
        for path in license_files(package):
            text = path.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n").rstrip()
            groups.setdefault(text, []).append(f"{package['name']} {package['version']} / {path.name}")
    for text, owners in groups.items():
        lines += [f"### {', '.join(owners)}", "", "```text", text, "```", ""]
    return "\n".join(lines).rstrip() + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if THIRD_PARTY_NOTICES.md is not up to date")
    arguments = parser.parse_args()
    current = NOTICES.read_text(encoding="utf-8")
    start = current.index(HEADING)
    following = current.find("\n## ", start + len(HEADING))
    end = len(current) if following < 0 else following + 1
    updated = current[:start] + render(packages()) + current[end:]
    if arguments.check:
        if updated != current:
            print("THIRD_PARTY_NOTICES.md is out of date: run python3 tools/generate-core-notices.py", file=sys.stderr)
            return 1
        print("Shared Rust core notices are up to date")
        return 0
    NOTICES.write_text(updated, encoding="utf-8")
    print(f"Wrote the shared Rust core notices for {len(packages())} packages")
    return 0


if __name__ == "__main__":
    sys.exit(main())
