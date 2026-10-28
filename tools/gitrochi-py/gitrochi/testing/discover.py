"""Test files, naming conventions across languages, and the runner each test belongs to."""

from __future__ import annotations

import importlib.util
import json
import re
import sys
from functools import lru_cache
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

JS_EXT = (".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".mts", ".cts")
LANG_BY_EXT = {
    ".py": "python", ".go": "go", ".rs": "rust", ".swift": "swift", ".java": "java", ".kt": "kotlin", ".rb": "ruby",
    ".cs": "csharp", ".vue": "js", ".svelte": "js",
}
for _ext in JS_EXT:
    LANG_BY_EXT[_ext] = "js"
GENERIC_STEMS = {"index", "mod", "main", "lib", "__init__", "init", "app", "utils", "util", "types", "common"}
# Files whose change can affect any test: everything runs (the same idea as gitch flow's affected selection).
RUN_ALL_FILES = {"package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "tsconfig.json",
                 "vitest.config.ts", "vitest.config.js", "vitest.config.mts", "jest.config.js", "jest.config.ts", "jest.config.cjs",
                 "Cargo.toml", "Cargo.lock", "go.mod", "go.sum", "pyproject.toml", "setup.cfg", "setup.py", "tox.ini",
                 "pytest.ini", "conftest.py", "requirements.txt", "requirements-dev.txt", "Package.swift", "Package.resolved",
                 "Pipfile", "Pipfile.lock", "poetry.lock", "uv.lock"}
RUN_ALL_PREFIXES = (".gitch/", ".github/workflows/")


def language(path: str) -> Optional[str]:
    name = path.rsplit("/", 1)[-1]
    if "." not in name:
        return None
    return LANG_BY_EXT.get("." + name.rsplit(".", 1)[-1].lower())


def _name(path: str) -> str:
    return path.rsplit("/", 1)[-1]


def is_test_file(path: str) -> bool:
    lang = language(path)
    name = _name(path)
    if lang == "python":
        return name != "conftest.py" and (name.startswith("test_") or name.endswith("_test.py") or
                                          (name.startswith("test") and name.endswith(".py") and "/tests/" in "/" + path))
    if lang == "js":
        return bool(re.search(r"\.(test|spec)\.[cm]?[jt]sx?$", name)) or "/__tests__/" in "/" + path
    if lang == "go":
        return name.endswith("_test.go")
    if lang == "rust":
        return bool(re.search(r"(^|/)tests/[^/]+\.rs$", path))
    if lang == "swift":
        return bool(re.search(r"Tests?\.swift$", name)) or "/Tests/" in "/" + path
    if lang in ("java", "kotlin", "csharp"):
        return bool(re.search(r"(Tests?|IT)\.(java|kt|cs)$", name))
    if lang == "ruby":
        return name.endswith(("_spec.rb", "_test.rb")) or name.startswith("test_")
    return False


def norm(stem: str) -> str:
    return re.sub(r"[^a-z0-9]", "", stem.lower())


def source_stem(path: str) -> str:
    name = _name(path)
    stem = name.split(".", 1)[0] if language(path) == "js" else name.rsplit(".", 1)[0]
    if stem.lower() in GENERIC_STEMS and "/" in path:
        return path.rsplit("/", 2)[-2]
    return stem


def subject_stem(test_path: str) -> Optional[str]:
    """The name of the code a test file is about: test_foo.py -> foo, FooTests.swift -> Foo, foo.test.ts -> foo."""
    name = _name(test_path)
    lang = language(test_path)
    patterns = {
        "python": [r"^test_(.+)\.py$", r"^(.+)_test\.py$", r"^test(.+)\.py$"],
        "js": [r"^(.+?)\.(?:test|spec)\.[cm]?[jt]sx?$", r"^(.+?)\.[cm]?[jt]sx?$"],
        "go": [r"^(.+)_test\.go$"],
        "rust": [r"^(.+)\.rs$"],
        "swift": [r"^(.+?)Tests?\.swift$"],
        "java": [r"^(.+?)(?:Tests?|IT)\.java$"],
        "kotlin": [r"^(.+?)(?:Tests?|IT)\.kt$"],
        "csharp": [r"^(.+?)Tests?\.cs$"],
        "ruby": [r"^(.+)_spec\.rb$", r"^(.+)_test\.rb$", r"^test_(.+)\.rb$"],
    }
    for pattern in patterns.get(lang or "", []):
        match = re.match(pattern, name)
        if match:
            stem = match.group(1).split(".", 1)[0]
            if stem.lower() in GENERIC_STEMS and "/" in test_path:
                parts = test_path.split("/")
                return parts[-2] if len(parts) >= 2 else stem
            return stem
    return None


def same_family(a: str, b: str) -> bool:
    la, lb = language(a), language(b)
    if la is None or lb is None:
        return False
    jvm = {"java", "kotlin"}
    return la == lb or (la in jvm and lb in jvm)


def _dirs(path: str) -> List[str]:
    return path.split("/")[:-1]


def naming_matches(source: str, tests: Sequence[str]) -> List[Tuple[str, float, str]]:
    """(test path, score, why) for tests that match a source file by name."""
    if is_test_file(source) or language(source) is None:
        return []
    stem = norm(source_stem(source))
    if not stem:
        return []
    src_dirs = _dirs(source)
    out: List[Tuple[str, float, str]] = []
    for test in tests:
        if not same_family(source, test):
            continue
        subject = subject_stem(test)
        test_dirs = _dirs(test)
        if language(source) == "go":
            # A Go test only tests the package in its own folder.
            if test_dirs != src_dirs:
                continue
            if subject and norm(subject) == stem:
                out.append((test, 0.95, f"{_name(test)} is the test file of {_name(source)}"))
            else:
                out.append((test, 0.6, f"same Go package as {_name(source)}"))
            continue
        if not subject or norm(subject) != stem:
            continue
        if test_dirs == src_dirs or test_dirs[:len(src_dirs)] == src_dirs and test_dirs[len(src_dirs):] in (["__tests__"], ["tests"], ["test"]):
            out.append((test, 0.95, f"{_name(test)} sits next to {_name(source)}"))
        elif _mirrors(src_dirs, test_dirs):
            out.append((test, 0.85, f"{test} mirrors {source}"))
        else:
            out.append((test, 0.6, f"{_name(test)} is named after {_name(source)}"))
    if len(out) > 3:
        # A generic name matching many files says little about each one.
        out = [(t, round(s * 0.6, 3) if s < 0.95 else s, why) for t, s, why in out]
    return out


def _mirrors(src_dirs: List[str], test_dirs: List[str]) -> bool:
    """tests/foo/test_bar.py mirrors src/foo/bar.py; Tests/AppTests/FooTests.swift mirrors Sources/App/Foo.swift."""
    def strip(dirs: List[str]) -> List[str]:
        roots = {"src", "lib", "sources", "source", "pkg", "internal", "tests", "test", "spec", "specs", "__tests__"}
        return [d.lower().replace("tests", "") for d in dirs if d.lower() not in roots]
    a, b = strip(src_dirs), strip(test_dirs)
    if not a and not b:
        return True
    return bool(a) and bool(b) and (a[-1] == b[-1] or a[-1].rstrip("s") == b[-1].rstrip("s"))


def rust_crate(path: str, files: Iterable[str]) -> Optional[str]:
    """The folder of the nearest Cargo.toml above a Rust file ('' for the repository root)."""
    manifests = _manifest_dirs(tuple(sorted(f for f in files if _name(f) == "Cargo.toml")))
    return _nearest(path, manifests)


@lru_cache(maxsize=64)
def _manifest_dirs(manifests: Tuple[str, ...]) -> Tuple[str, ...]:
    return tuple(m.rsplit("/", 1)[0] if "/" in m else "" for m in manifests)


def _nearest(path: str, dirs: Sequence[str]) -> Optional[str]:
    best: Optional[str] = None
    for d in dirs:
        if d == "" or path.startswith(d + "/"):
            if best is None or len(d) > len(best):
                best = d
    return best


def project_dir(path: str, files: Sequence[str], markers: Sequence[str]) -> Optional[str]:
    """The nearest folder above `path` that holds one of the marker files ('' is the repository root)."""
    dirs = sorted({(f.rsplit("/", 1)[0] if "/" in f else "") for f in files if _name(f) in markers})
    return _nearest(path, dirs)


@lru_cache(maxsize=256)
def _package_json(root: str, rel_dir: str) -> Dict[str, object]:
    path = Path(root) / rel_dir / "package.json" if rel_dir else Path(root) / "package.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def js_runner(root: Path, rel_dir: str) -> Optional[str]:
    pkg = _package_json(str(root), rel_dir)
    deps: Dict[str, object] = {}
    for key in ("devDependencies", "dependencies", "peerDependencies"):
        value = pkg.get(key)
        if isinstance(value, dict):
            deps.update(value)
    scripts = pkg.get("scripts") if isinstance(pkg.get("scripts"), dict) else {}
    test_script = str((scripts or {}).get("test", ""))
    if "vitest" in deps or "vitest" in test_script:
        return "vitest"
    if "jest" in deps or "jest" in test_script:
        return "jest"
    return None


def python_runner(root: Path, rel_dir: str, test_files: Sequence[str], python: str = sys.executable) -> str:
    """pytest when it is installed for this interpreter and the project uses it; unittest otherwise."""
    if python == sys.executable and importlib.util.find_spec("pytest") is None:
        return "unittest"
    base = Path(root) / rel_dir if rel_dir else Path(root)
    if (base / "pytest.ini").is_file() or (base / "conftest.py").is_file():
        return "pytest"
    for name, marker in (("pyproject.toml", "[tool.pytest"), ("setup.cfg", "[tool:pytest]"), ("tox.ini", "[pytest]")):
        try:
            if marker in (base / name).read_text(encoding="utf-8", errors="replace"):
                return "pytest"
        except OSError:
            pass
    for test in test_files[:50]:
        try:
            head = (Path(root) / test).read_text(encoding="utf-8", errors="replace")[:4000]
        except OSError:
            continue
        if re.search(r"^\s*(import pytest|from pytest\b)", head, re.MULTILINE):
            return "pytest"
    return "unittest"


def go_test_names(root: Path, test_file: str) -> List[str]:
    try:
        text = (Path(root) / test_file).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    return re.findall(r"^func\s+(Test[A-Za-z0-9_]*)\s*\(\s*\w+\s+\*testing\.T\s*\)", text, re.MULTILINE)


def rust_has_unit_tests(root: Path, path: str) -> bool:
    try:
        return "#[cfg(test)]" in (Path(root) / path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False


def rust_module_path(path: str, crate: str) -> Optional[str]:
    """src/a/b.rs -> a::b (None for the crate root, whose tests match everything)."""
    rel = path[len(crate) + 1:] if crate else path
    if not rel.startswith("src/"):
        return None
    parts = rel[len("src/"):-3].split("/")
    if parts[-1] == "mod":
        parts = parts[:-1]
    if parts in ([], ["lib"], ["main"]):
        return None
    return "::".join(parts)
