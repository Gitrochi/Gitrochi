"""Command line entry point: `python3 -m gitrochi <command>`.

Exit codes: 0 success, 1 failure (or findings above the threshold), 2 usage error.
With --json, errors are printed as {"schemaVersion": 1, "error": {"code", "message"}} on stdout.
"""

from __future__ import annotations

import argparse
import os
import sys
import traceback
from typing import List, Optional, Sequence

from gitrochi import __version__, redact
from gitrochi.util import Failure, UsageError, dumps, envelope, eprint


class Parser(argparse.ArgumentParser):
    """argparse that raises instead of exiting, so usage errors can be reported as JSON with exit code 2."""

    def error(self, message: str) -> None:  # type: ignore[override]
        raise UsageError(f"{message} (see `{self.prog} --help`)")


def _common() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="print one JSON document (for machines)")
    common.add_argument("--repo", default=".", metavar="DIR", help="repository folder (default: current folder)")
    return common


def _index_options() -> argparse.ArgumentParser:
    opts = argparse.ArgumentParser(add_help=False)
    group = opts.add_argument_group("repository index")
    group.add_argument("--index-bin", metavar="PATH", help="gitrochi-index executable (default: $GITROCHI_INDEX_BIN, PATH, crates/target/release)")
    group.add_argument("--index-db", metavar="FILE", help="index database (default: <git common dir>/gitrochi/index.sqlite3)")
    group.add_argument("--no-index", action="store_true", help="do not use the repository index (also GITROCHI_INDEX=0)")
    return opts


def build_parser() -> Parser:
    from gitrochi.analysis import command as analyze_cmd
    from gitrochi.review import command as review_cmd
    from gitrochi.runtime import command as runtime_cmd
    from gitrochi.testing import command as test_cmd

    parser = Parser(prog="gitrochi-py",
                    description="Gitrochi's Python tools: AI code review, repository analysis, test automation and runtime management.",
                    epilog="Run `gitrochi-py <command> --help` for the options of a command. Exit codes: 0 ok, 1 failure, 2 usage.")
    parser.add_argument("--version", action="version", version=f"gitrochi-py {__version__}")
    sub = parser.add_subparsers(dest="command", metavar="<command>", parser_class=Parser)
    common = _common()
    index_opts = _index_options()
    review_cmd.register(sub, common, index_opts)
    analyze_cmd.register(sub, common, index_opts)
    test_cmd.register(sub, common, index_opts)
    runtime_cmd.register(sub, common)
    return parser


def _wants_json(argv: Sequence[str]) -> bool:
    for i, arg in enumerate(argv):
        if arg in ("--json", "--format=json"):
            return True
        if arg == "--format" and i + 1 < len(argv) and argv[i + 1] == "json":
            return True
    return False


def _report(as_json: bool, code: str, message: str, details: object = None) -> None:
    message = redact.redact(message)
    if as_json:
        doc = envelope("error", error={"code": code, "message": message, "details": details})
        print(dumps(doc))
    else:
        eprint(f"gitrochi-py: {message}")


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    as_json = _wants_json(argv)
    try:
        parser = build_parser()
        args = parser.parse_args(argv)
        func = getattr(args, "func", None)
        if func is None:
            parser.print_help(sys.stderr)
            return 2
        return int(func(args) or 0)
    except UsageError as exc:
        _report(as_json, "USAGE", str(exc))
        return 2
    except Failure as exc:
        _report(as_json, exc.code, exc.message, exc.details)
        return 1
    except KeyboardInterrupt:
        _report(as_json, "INTERRUPTED", "interrupted")
        return 1
    except SystemExit as exc:
        # argparse --help / --version
        return int(exc.code or 0) if isinstance(exc.code, int) else 0
    except Exception as exc:  # pragma: no cover - last resort, keeps secrets out of tracebacks
        if os.environ.get("GITROCHI_DEBUG"):
            traceback.print_exc()
        _report(as_json, "INTERNAL", f"{type(exc).__name__}: {exc}")
        return 1
