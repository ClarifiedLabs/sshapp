"""Shared assertion helpers for the tooling regression checks."""

from __future__ import annotations

import pathlib
import sys


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def fail(message: str) -> None:
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(1)


def read(path: pathlib.Path) -> str:
    if not path.exists():
        fail(f"missing expected file: {path.relative_to(REPO_ROOT)}")
    return path.read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def require_contains(text: str, needle: str, context: str) -> None:
    require(needle in text, f"{context} must contain {needle!r}")


def require_absent(text: str, needle: str, context: str) -> None:
    require(needle not in text, f"{context} must not contain {needle!r}")


def require_count(text: str, needle: str, expected: int, context: str) -> None:
    actual = text.count(needle)
    require(actual == expected, f"{context} must contain {needle!r} {expected} times; found {actual}")
