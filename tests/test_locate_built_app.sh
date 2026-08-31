#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LOCATOR="$ROOT_DIR/scripts/locate-built-app.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

make_app() {
  local derived="$1"
  local configuration="$2"
  local name="$3"
  local executable_mode="${4:-executable}"
  local app="$derived/Build/Products/$configuration/$name.app"
  mkdir -p "$app/Contents/MacOS"
  printf '#!/usr/bin/env bash\n' > "$app/Contents/MacOS/$name"
  if [[ "$executable_mode" == "executable" ]]; then
    chmod +x "$app/Contents/MacOS/$name"
  fi
  printf '%s\n' "$app"
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local context="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $context: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

OLD_APP="$(make_app "$FIXTURE/Old With Spaces" Debug "Programa DEV")"
NEW_APP="$(make_app "$FIXTURE/New With Spaces" Debug "Programa DEV")"
NEWER_FALLBACK="$(make_app "$FIXTURE/Newest Fallback" Debug Programa)"
touch -t 202601010101 "$OLD_APP"
touch -t 202602020202 "$NEW_APP"
touch -t 202605050505 "$NEWER_FALLBACK"
FOUND="$($LOCATOR --configuration Debug --primary "Programa DEV" --fallback Programa --derived-data-root "$FIXTURE")"
assert_equal "$NEW_APP" "$FOUND" "primary name wins before newer fallback"

ISOLATED_ROOT="$FIXTURE/Isolated Job Root"
ISOLATED_APP="$(make_app "$ISOLATED_ROOT" Debug "Programa DEV")"
OUTSIDE_NEWEST="$(make_app "$FIXTURE/Unrelated Job" Debug "Programa DEV")"
touch -t 202603030303 "$ISOLATED_APP"
touch -t 202612121212 "$OUTSIDE_NEWEST"
FOUND="$($LOCATOR --configuration Debug --primary "Programa DEV" --derived-data-root "$ISOLATED_ROOT")"
assert_equal "$ISOLATED_APP" "$FOUND" "derived-data root isolates concurrent job artifacts"

TIE_A="$(make_app "$FIXTURE/A Equal" Release Programa)"
TIE_B="$(make_app "$FIXTURE/B Equal" Release Programa)"
touch -t 202603030303 "$TIE_A" "$TIE_B"
FOUND="$($LOCATOR --configuration Release --primary Programa --derived-data-root "$FIXTURE")"
assert_equal "$TIE_A" "$FOUND" "lexical tie-break"

FALLBACK_ROOT="$FIXTURE/Fallback Only"
FALLBACK_APP="$(make_app "$FALLBACK_ROOT" Debug Programa)"
FOUND="$($LOCATOR --configuration Debug --primary "Programa DEV" --fallback Programa --derived-data-root "$FALLBACK_ROOT")"
assert_equal "$FALLBACK_APP" "$FOUND" "fallback name"

EXACT_ROOT="$FIXTURE/Exact"
EXACT_APP="$(make_app "$EXACT_ROOT" Debug "Programa DEV")"
OUTSIDE_APP="$(make_app "$FIXTURE/Outside Newer" Debug "Programa DEV")"
touch -t 202604040404 "$OUTSIDE_APP"
FOUND="$($LOCATOR --configuration Debug --primary "Programa DEV" --exact-app "$EXACT_APP")"
assert_equal "$EXACT_APP" "$FOUND" "exact path isolation"

NONEXEC_ROOT="$FIXTURE/NonExecutable"
make_app "$NONEXEC_ROOT" Debug "Programa DEV" nonexecutable >/dev/null
if "$LOCATOR" --configuration Debug --primary "Programa DEV" --derived-data-root "$NONEXEC_ROOT" >/dev/null 2>&1; then
  echo "FAIL: non-executable app was accepted" >&2
  exit 1
fi
if "$LOCATOR" --configuration Debug --primary Missing --derived-data-root "$FIXTURE" >/dev/null 2>&1; then
  echo "FAIL: missing app was accepted" >&2
  exit 1
fi
if "$LOCATOR" --configuration Debug --primary "Programa DEV" --exact-app "$FIXTURE/does-not-exist.app" >/dev/null 2>&1; then
  echo "FAIL: missing exact app was accepted" >&2
  exit 1
fi

echo "locate-built-app behavior: PASS"
