#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLASSIFIER="${REPO_ROOT}/scripts/classify_ci_changes.sh"

if [[ ! -f "${CLASSIFIER}" ]]; then
  echo "FAIL: missing CI change classifier at scripts/classify_ci_changes.sh" >&2
  exit 1
fi

run_case() {
  local name="$1"
  local expected_app="$2"
  local expected_daemon="$3"
  local changed_paths="$4"
  local output
  local expected

  if ! output="$(printf '%s' "${changed_paths}" | bash "${CLASSIFIER}")"; then
    echo "FAIL: ${name}: classifier exited non-zero" >&2
    exit 1
  fi

  printf -v expected \
    'run_app_jobs=%s\nrun_remote_daemon_jobs=%s' \
    "${expected_app}" \
    "${expected_daemon}"

  if [[ "${output}" != "${expected}" ]]; then
    echo "FAIL: ${name}: unexpected classifier output" >&2
    printf 'expected:\n%s\n' "${expected}" >&2
    printf 'actual:\n%s\n' "${output}" >&2
    exit 1
  fi
}

run_case \
  "app path before daemon path" \
  true \
  true \
  $'Sources/TerminalController.swift\ndaemon/remote/cmd/programad-remote/main.go\n'

run_case \
  "daemon path before app path" \
  true \
  true \
  $'daemon/remote/cmd/programad-remote/main.go\nSources/TerminalController.swift\n'

run_case \
  "daemon path only" \
  false \
  true \
  $'daemon/remote/cmd/programad-remote/main.go\n'

run_case \
  "app path only" \
  true \
  false \
  $'Sources/TerminalController.swift\n'

run_case \
  "app icon asset" \
  true \
  false \
  $'Assets.xcassets/AppIcon.appiconset/icon.png\n'

run_case \
  "non-localization bundled image" \
  true \
  false \
  $'Resources/ghostty/themes/preview.png\n'

run_case \
  "documentation workflow and localization paths only" \
  false \
  false \
  $'docs/socket-control.md\nREADME.md\n.github/workflows/ci.yml\nResources/Localizable.xcstrings\nResources/ja.lproj/Localizable.strings\n'

run_case \
  "empty changed path set" \
  true \
  true \
  ""

echo "CI change classification behavior: PASS"
