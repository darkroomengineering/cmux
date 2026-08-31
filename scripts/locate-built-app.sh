#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

CONFIGURATION=""
PRIMARY_NAME=""
FALLBACK_NAME=""
DERIVED_DATA_ROOT=""
EXACT_APP=""

usage() {
  echo "Usage: $0 --configuration <name> --primary <app-name> [--fallback <app-name>] (--derived-data-root <path> | --exact-app <path>)" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) CONFIGURATION="${2:-}"; shift 2 ;;
    --primary) PRIMARY_NAME="${2:-}"; shift 2 ;;
    --fallback) FALLBACK_NAME="${2:-}"; shift 2 ;;
    --derived-data-root) DERIVED_DATA_ROOT="${2:-}"; shift 2 ;;
    --exact-app) EXACT_APP="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$CONFIGURATION" || -z "$PRIMARY_NAME" ]]; then
  usage
  exit 2
fi
if [[ -n "$DERIVED_DATA_ROOT" && -n "$EXACT_APP" ]] || [[ -z "$DERIVED_DATA_ROOT" && -z "$EXACT_APP" ]]; then
  echo "error: specify exactly one of --derived-data-root or --exact-app" >&2
  exit 2
fi

valid_app() {
  local app="$1"
  local executable_name="$PRIMARY_NAME"
  [[ -d "$app" ]] || return 1
  if [[ "$(basename "$app")" == "${FALLBACK_NAME}.app" ]]; then
    executable_name="$FALLBACK_NAME"
  fi
  [[ -x "$app/Contents/MacOS/$executable_name" ]]
}

if [[ -n "$EXACT_APP" ]]; then
  if [[ "$EXACT_APP" != /* ]]; then
    echo "error: --exact-app must be an absolute path" >&2
    exit 2
  fi
  if ! valid_app "$EXACT_APP"; then
    echo "error: app is missing or its matching executable is not executable: $EXACT_APP" >&2
    exit 1
  fi
  printf '%s\n' "$EXACT_APP"
  exit 0
fi

if [[ ! -d "$DERIVED_DATA_ROOT" ]]; then
  echo "error: DerivedData root does not exist: $DERIVED_DATA_ROOT" >&2
  exit 1
fi
DERIVED_DATA_ROOT="$(cd "$DERIVED_DATA_ROOT" && pwd -P)"

stat_mtime() {
  local value=""
  value="$(/usr/bin/stat -f '%m' "$1" 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  value="$(/usr/bin/stat -c '%Y' "$1" 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  echo "error: could not read app modification time: $1" >&2
  return 1
}

find_newest_named_app() {
  local wanted_name="$1"
  local candidate=""
  local candidate_mtime=""
  local selected=""
  local selected_mtime="-1"

  while IFS= read -r -d '' candidate; do
    [[ "$(basename "$candidate")" == "${wanted_name}.app" ]] || continue
    [[ "$(dirname "$candidate")" == */Build/Products/"$CONFIGURATION" ]] || continue
    valid_app "$candidate" || continue
    candidate_mtime="$(stat_mtime "$candidate")"
    if (( candidate_mtime > selected_mtime )) || {
      (( candidate_mtime == selected_mtime )) && [[ -n "$selected" && "$candidate" < "$selected" ]]
    }; then
      selected="$candidate"
      selected_mtime="$candidate_mtime"
    fi
  done < <(LC_ALL=C find "$DERIVED_DATA_ROOT" -type d -name '*.app' -print0 2>/dev/null)

  [[ -n "$selected" ]] || return 1
  printf '%s\n' "$selected"
}

if APP_PATH="$(find_newest_named_app "$PRIMARY_NAME")"; then
  printf '%s\n' "$APP_PATH"
  exit 0
fi
if [[ -n "$FALLBACK_NAME" ]] && APP_PATH="$(find_newest_named_app "$FALLBACK_NAME")"; then
  printf '%s\n' "$APP_PATH"
  exit 0
fi

echo "error: ${PRIMARY_NAME}.app not found with an executable in $DERIVED_DATA_ROOT" >&2
exit 1
