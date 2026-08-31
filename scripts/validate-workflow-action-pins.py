#!/usr/bin/env python3
"""Reject mutable external GitHub Action references in workflow files."""

from __future__ import annotations

import re
import sys
from pathlib import Path


USES_KEY = re.compile(r"^\s*(?:-\s*)?uses\s*:\s*(.*?)\s*$")
PINNED_ACTION = re.compile(r"^[^\s/@]+/[^\s@]+@([0-9a-fA-F]{40})$")


def parse_scalar(raw: str) -> str:
    if not raw:
        return ""
    if raw[0] in {"'", '"'}:
        quote = raw[0]
        escaped = False
        value: list[str] = []
        for char in raw[1:]:
            if quote == '"' and escaped:
                value.append(char)
                escaped = False
            elif quote == '"' and char == "\\":
                escaped = True
            elif char == quote:
                return "".join(value)
            else:
                value.append(char)
        return ""
    return raw.split(" #", 1)[0].strip()


def workflow_files(root: Path) -> list[Path]:
    workflow_root = root / ".github" / "workflows"
    return sorted((*workflow_root.rglob("*.yml"), *workflow_root.rglob("*.yaml")))


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    failures: list[str] = []
    checked = 0
    for path in workflow_files(root):
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            match = USES_KEY.fullmatch(line)
            if match is None:
                continue
            reference = parse_scalar(match.group(1))
            if reference.startswith("./"):
                continue
            checked += 1
            if PINNED_ACTION.fullmatch(reference) is None:
                failures.append(
                    f"{path.relative_to(root)}:{line_number}: external action must use a 40-character commit SHA: {reference or '<empty>'}"
                )
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"validated {checked} external action references; all are pinned")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
