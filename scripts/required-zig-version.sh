#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MANIFEST="$ROOT_DIR/ghostty/build.zig.zon"

if [[ ! -f "$MANIFEST" ]]; then
  echo "error: Ghostty submodule is not initialized: $MANIFEST" >&2
  exit 1
fi

python3 - "$MANIFEST" <<'PY'
import pathlib
import re
import sys

manifest = pathlib.Path(sys.argv[1])
pattern = re.compile(r'^\s*\.minimum_zig_version\s*=\s*"([^"]+)"\s*,\s*$')
matches = [
    match.group(1)
    for line in manifest.read_text(encoding="utf-8").splitlines()
    if (match := pattern.fullmatch(line))
]
if len(matches) != 1:
    raise SystemExit(
        f"error: expected exactly one .minimum_zig_version field in {manifest}, found {len(matches)}"
    )
version = matches[0]
if re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version) is None:
    raise SystemExit(f"error: invalid Zig semantic version in {manifest}: {version!r}")
print(version)
PY
