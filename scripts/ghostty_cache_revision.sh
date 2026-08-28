#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_PATH="${1:-$SCRIPT_DIR/../ghostty}"

if [ ! -e "$REPO_PATH" ]; then
  echo "ghostty cache revision: path does not exist: $REPO_PATH" >&2
  exit 1
fi

if [ ! -d "$REPO_PATH" ]; then
  echo "ghostty cache revision: path is not a directory: $REPO_PATH" >&2
  exit 1
fi

if ! CANONICAL_REPO_PATH="$(cd "$REPO_PATH" 2>/dev/null && pwd -P)"; then
  echo "ghostty cache revision: cannot resolve path: $REPO_PATH" >&2
  exit 1
fi

if ! INSIDE_WORK_TREE="$(git -C "$REPO_PATH" rev-parse --is-inside-work-tree 2>/dev/null)"; then
  echo "ghostty cache revision: path is not a Git directory: $REPO_PATH" >&2
  exit 1
fi

if [ "$INSIDE_WORK_TREE" != "true" ]; then
  echo "ghostty cache revision: path is not a Git worktree: $REPO_PATH" >&2
  exit 1
fi

if ! TOP_LEVEL="$(git -C "$REPO_PATH" rev-parse --show-toplevel 2>/dev/null)" \
  || ! CANONICAL_TOP_LEVEL="$(cd "$TOP_LEVEL" 2>/dev/null && pwd -P)"; then
  echo "ghostty cache revision: cannot resolve Git worktree root: $REPO_PATH" >&2
  exit 1
fi

if [ "$CANONICAL_REPO_PATH" != "$CANONICAL_TOP_LEVEL" ]; then
  echo "ghostty cache revision: path is not the Git worktree root: $REPO_PATH" >&2
  exit 1
fi

if ! REVISION="$(git -C "$REPO_PATH" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)"; then
  echo "ghostty cache revision: HEAD is not a commit: $REPO_PATH" >&2
  exit 1
fi

if [[ ! "$REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ghostty cache revision: HEAD is not a 40-character lowercase SHA-1: $REPO_PATH" >&2
  exit 1
fi

printf '%s\n' "$REVISION"
