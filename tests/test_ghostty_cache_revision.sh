#!/usr/bin/env bash
# Regression test: cache keys must follow the checked-out Ghostty revision.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ghostty_cache_revision.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO_DIR="$TMP_DIR/ghostty"
NESTED_NON_GIT_DIR="$REPO_DIR/ordinary-directory"
NON_GIT_DIR="$TMP_DIR/not-a-repository"
MISSING_DIR="$TMP_DIR/missing"

git init --object-format=sha1 -q "$REPO_DIR"
git -C "$REPO_DIR" config user.name "Programa Test"
git -C "$REPO_DIR" config user.email "programa-test@example.invalid"

printf 'first revision\n' > "$REPO_DIR/revision.txt"
git -C "$REPO_DIR" add revision.txt
git -C "$REPO_DIR" commit -q -m "fixture: first revision"

FIRST_EXPECTED="$(git -C "$REPO_DIR" rev-parse HEAD)"
FIRST_ACTUAL="$("$SCRIPT" "$REPO_DIR")"

if [[ ! "$FIRST_ACTUAL" =~ ^[0-9a-f]{40}$ ]]; then
  echo "FAIL: revision helper did not print exactly one 40-character Git revision" >&2
  exit 1
fi

if [ "$FIRST_ACTUAL" != "$FIRST_EXPECTED" ]; then
  echo "FAIL: revision helper did not report the first checked-out revision" >&2
  exit 1
fi

printf 'second revision\n' >> "$REPO_DIR/revision.txt"
git -C "$REPO_DIR" add revision.txt
git -C "$REPO_DIR" commit -q -m "fixture: second revision"

SECOND_EXPECTED="$(git -C "$REPO_DIR" rev-parse HEAD)"
SECOND_ACTUAL="$("$SCRIPT" "$REPO_DIR")"

if [ "$SECOND_ACTUAL" != "$SECOND_EXPECTED" ]; then
  echo "FAIL: revision helper did not report the new checked-out revision" >&2
  exit 1
fi

if [ "$SECOND_ACTUAL" = "$FIRST_ACTUAL" ]; then
  echo "FAIL: revision helper reused the previous revision after a new commit" >&2
  exit 1
fi

mkdir -p "$NESTED_NON_GIT_DIR"
if "$SCRIPT" "$NESTED_NON_GIT_DIR" >"$TMP_DIR/nested-non-git.out" 2>&1; then
  echo "FAIL: revision helper accepted an ordinary directory nested inside a Git worktree" >&2
  exit 1
fi

mkdir -p "$NON_GIT_DIR"
if "$SCRIPT" "$NON_GIT_DIR" >"$TMP_DIR/non-git.out" 2>&1; then
  echo "FAIL: revision helper accepted a directory that is not a Git working tree" >&2
  exit 1
fi

if "$SCRIPT" "$MISSING_DIR" >"$TMP_DIR/missing.out" 2>&1; then
  echo "FAIL: revision helper accepted a missing path" >&2
  exit 1
fi

echo "PASS: Ghostty cache revision follows the checked-out commit"
