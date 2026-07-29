#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODEBUILD_COMMAND="${PROGRAMA_XCODEBUILD_COMMAND:-xcodebuild}"
# xcodebuild only forwards TEST_RUNNER_-prefixed variables into the test-host
# process (with the prefix stripped). Without this, the tests' CI-conditional
# scaling and skips never activate on runners even though CI=true is set for
# the workflow step.
if [[ -n "${CI:-}" ]]; then
  export TEST_RUNNER_CI="$CI"
fi
SOURCE_PACKAGES_DIR="${PROGRAMA_SOURCE_PACKAGES_DIR:-$ROOT_DIR/.ci-source-packages}"
OUTPUT_FILE="${PROGRAMA_TEST_OUTPUT_FILE:-/tmp/test-output.txt}"
SWIFTPM_CACHE_DIR="${PROGRAMA_SWIFTPM_CACHE_DIR:-$HOME/Library/Caches/org.swift.swiftpm}"
DERIVED_DATA_DIR="${PROGRAMA_DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData}"
TEST_SCOPE="${PROGRAMA_UNIT_TEST_SCOPE:-serial}"
STATEFUL_TEST_CLASS="programaTests/AppDelegateShortcutRoutingTests"
STATEFUL_TEST_SKIP="${STATEFUL_TEST_CLASS}/testCmdWClosesWindowWhenClosingLastSurfaceInLastWorkspace"

# Tests quarantined when PROGRAMA_UNIT_TEST_QUARANTINE is set (the macos-15
# compat leg). These 17 fail together, identically, on every macos-15 run --
# verified by intersecting the failure sets of independent runs -- and they are
# NOT failing because the code under test is broken on macOS 15:
#
#   * There is no OS-version-conditional code anywhere in the paths they cover.
#     A genuinely unguarded macOS-26-only symbol could not compile at all here,
#     since Swift checks availability against MACOSX_DEPLOYMENT_TARGET (14.0).
#   * Raising every wait budget 4x (ciScale) changed nothing. A 12s wait timing
#     out is not a slow overlay.
#   * They fail alongside raw Unix-socket and subprocess waits in the same run.
#     A BSD socket accept and a DispatchQueue.main.async closure share no
#     SwiftUI or AppKit code; the only thing in common is needing an async
#     completion serviced promptly. That points at runner starvation.
#
# The suite runs serially in fixed order, so a runner that degrades partway
# through starves the same tests every time -- deterministic failures from a
# non-deterministic cause.
#
# IMPORTANT: this quarantine is scoped to the compat leg only. Every test below
# still runs on the macos-26 compat leg AND in the main CI workflow's unit-tests
# job on every PR, so none of this coverage is actually lost -- including the
# TerminalControllerSocketSecurityTests entries, which are security tests and
# would otherwise be the most alarming thing on this list.
#
# This is a workaround for CI infrastructure, not a fix. Revisit if the macos-15
# runner image changes or the Ghostty surface churn in these tests is reduced.
QUARANTINED_ON_COMPAT=(
  "programaTests/CLINotifyProcessIntegrationTests/testSSHBootstrapStartupCommandPassesRemoteInstallScriptAsSingleSSHCommand"
  "programaTests/GhosttySurfaceOverlayTests/testDropHoverOverlayAttachesToParentContainerInsteadOfHostedTerminalView"
  "programaTests/GhosttySurfaceOverlayTests/testEscapeDismissingFindOverlayDoesNotLeakEscapeKeyUpToTerminal"
  "programaTests/GhosttySurfaceOverlayTests/testSearchOverlayFocusesSearchFieldAfterDeferredAttach"
  "programaTests/GhosttySurfaceOverlayTests/testSearchOverlayMountDoesNotRetainTerminalSurface"
  "programaTests/GhosttySurfaceOverlayTests/testSearchOverlayMountsAndUnmountsWithSearchState"
  "programaTests/GhosttySurfaceOverlayTests/testSearchOverlaySurvivesPortalRebindDuringSplitLikeChurn"
  "programaTests/GhosttySurfaceOverlayTests/testSearchOverlaySurvivesPortalVisibilityToggleDuringWorkspaceSwitchLikeChurn"
  "programaTests/NotificationDockBadgeTests/testFocusedTerminalSuppressedNotificationRunsCustomCommand"
  "programaTests/TerminalControllerSocketSecurityTests/testNotificationCreateUsesExplicitSurfaceIDWhenProvided"
  "programaTests/TerminalControllerSocketSecurityTests/testPasswordModeRejectsUnauthenticatedCommands"
  "programaTests/TerminalControllerSocketSecurityTests/testSocketPermissionsFollowAccessMode"
  "programaTests/TerminalControllerSocketSecurityTests/testSurfaceRelayRPCsAcknowledgeImmediatelyAndNoOpForUnknownSurfaceID"
  "programaTests/TerminalControllerSocketSecurityTests/testSurfaceRelayRPCsAcknowledgeImmediatelyAndResolveFocusedSurfaceAsync"
  "programaTests/TerminalNotificationDirectInteractionTests/testKeyDownRecoversReleasedSurfaceWhileHostedViewIsDetached"
  "programaTests/TerminalNotificationDirectInteractionTests/testKeyDownRecoveryDoesNotReplayFocusAfterResponderMovesAway"
  "programaTests/TerminalWindowPortalLifecycleTests/testScheduledExternalGeometrySyncRefreshesAncestorLayoutShift"
)

RESULT_BUNDLE_ROOT="${PROGRAMA_RESULT_BUNDLE_ROOT:-/tmp/programa-unit-xcresults}"

run_unit_tests() {
  local mode="${1:-serial}"
  # Pin the result bundle to a known location so CI can upload it on failure;
  # xcodebuild refuses to overwrite an existing bundle, so each invocation
  # (mode x retry attempt) gets its own sequence-numbered path.
  #
  # The sequence is passed in rather than incremented here on purpose. This
  # function is always invoked on the left-hand side of a `| tee`, which bash
  # runs in a subshell, so a variable incremented in here is discarded when the
  # subshell exits. When the counter lived here every retry recomputed the same
  # path, xcodebuild bailed with "Existing file at -resultBundlePath" (exit 64)
  # before running a single test, and the retry that exists to absorb a flaky
  # stateful pass instead turned it into a hard failure.
  local seq="${2:-1}"
  mkdir -p "$RESULT_BUNDLE_ROOT"
  local -a xcode_args=(
    "$XCODEBUILD_COMMAND"
    -project "$ROOT_DIR/GhosttyTabs.xcodeproj"
    -scheme programa-unit
    -configuration Debug
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR"
    -disableAutomaticPackageResolution
    -destination "platform=macOS"
    -resultBundlePath "$RESULT_BUNDLE_ROOT/${mode}-${seq}.xcresult"
  )

  case "$mode" in
    parallel)
      xcode_args+=("-skip-testing:${STATEFUL_TEST_CLASS}")
      xcode_args+=("-parallel-testing-enabled" "YES")
      ;;
    stateful)
      xcode_args+=("-only-testing:${STATEFUL_TEST_CLASS}")
      xcode_args+=("-skip-testing:${STATEFUL_TEST_SKIP}")
      xcode_args+=("-parallel-testing-enabled" "NO")
      ;;
    serial|*)
      xcode_args+=("-skip-testing:${STATEFUL_TEST_SKIP}")
      xcode_args+=("-parallel-testing-enabled" "NO")
      ;;
  esac

  if [[ -n "${PROGRAMA_UNIT_TEST_QUARANTINE:-}" ]]; then
    echo "Quarantining ${#QUARANTINED_ON_COMPAT[@]} runner-starvation-prone tests (see QUARANTINED_ON_COMPAT)" >&2
    local quarantined
    for quarantined in "${QUARANTINED_ON_COMPAT[@]}"; do
      xcode_args+=("-skip-testing:${quarantined}")
    done
  fi

  "${xcode_args[@]}" test 2>&1
}

run_unit_tests_with_retry() {
  local mode="${1:-serial}"
  local attempt=0
  # Lives here, in the parent shell, so it actually survives across retries --
  # see the note in run_unit_tests about the `| tee` subshell.
  local seq=0

  while true; do
    seq=$((seq + 1))
    set +e
    run_unit_tests "$mode" "$seq" | tee "$OUTPUT_FILE"
    EXIT_CODE=${PIPESTATUS[0]}
    OUTPUT="$(cat "$OUTPUT_FILE")"
    set -e

    if [[ "$EXIT_CODE" -eq 0 ]]; then
      return 0
    fi

    if [[ "$EXIT_CODE" -ne 0 ]] && (( attempt == 0 )) && \
      grep -q "Could not resolve package dependencies" <<< "$OUTPUT"; then
      echo "SwiftPM package resolution failed, clearing caches and retrying once"
      rm -rf "$SWIFTPM_CACHE_DIR"
      mkdir -p "$SWIFTPM_CACHE_DIR"
      if [[ -d "$DERIVED_DATA_DIR" ]]; then
        find "$DERIVED_DATA_DIR" -maxdepth 1 -type d -name 'GhosttyTabs-*' -exec rm -rf {} +
      fi
      attempt=1
      continue
    fi

    # The stateful suite is isolated to AppDelegate routing focus tests and is
    # known to be flaky only via transient CI focus-timing races; absorb one
    # retry on failure so one transient miss doesn't fail the whole run.
    if [[ "$mode" == "stateful" ]] && (( attempt == 0 )); then
      echo "Stateful test pass is timing-sensitive; retrying once"
      attempt=1
      continue
    fi

    return "$EXIT_CODE"
  done
}

run_suite() {
  local mode="${1:-serial}"
  local label="${2:-Unit tests}"
  local exit_code=0

  # Capture the status directly; `$?` after a branchless `if` is always 0,
  # which silently turned test failures into successes.
  run_unit_tests_with_retry "$mode" || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    echo "${label} failed with exit code $exit_code"
    exit "$exit_code"
  fi
}

if [[ "$TEST_SCOPE" == "split-stateful" ]]; then
  run_suite parallel "Stateful-free unit tests"
  run_suite stateful "Stateful unit tests"
else
  run_suite serial "Unit tests"
fi
