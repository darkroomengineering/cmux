#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: PROGRAMA_SOCKET_PATH=/tmp/programa-debug-<tag>.sock $0 <window|sidebar|tabBar|browserToolbar|overlays> [output-directory]" >&2
}

surface="${1:-}"
output_dir="${2:-/tmp/programa-glass-memory}"
socket_path="${PROGRAMA_SOCKET_PATH:-}"

case "$surface" in
  window|sidebar|tabBar|browserToolbar|overlays) ;;
  *) usage; exit 2 ;;
esac

if [[ -z "$socket_path" || ! -S "$socket_path" ]]; then
  echo "PROGRAMA_SOCKET_PATH must point to a running tagged Debug app socket" >&2
  exit 2
fi

pid="$(lsof -t "$socket_path" | head -n 1)"
if [[ -z "$pid" ]]; then
  echo "No Programa process owns $socket_path" >&2
  exit 1
fi

mkdir -p "$output_dir"

set_surface() {
  local target="$1"
  local enabled="$2"
  local response
  response="$(printf '{"id":1,"method":"debug.glass.set","params":{"surface":"%s","enabled":%s}}\n' "$target" "$enabled" | nc -w 2 -U "$socket_path")"
  if ! printf '%s\n' "$response" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true'; then
    echo "debug.glass.set failed: $response" >&2
    exit 1
  fi
}

capture() {
  local state="$1"
  local prefix="$output_dir/${surface}-${state}"
  footprint --pid "$pid" --format bytes --noCategories --json "$prefix.json" > "$prefix.txt"
  echo "$state snapshot: $prefix.txt"
  grep -E 'Footprint|footprint' "$prefix.txt" | tail -n 1 || true
}

for candidate in window sidebar tabBar browserToolbar overlays; do
  set_surface "$candidate" false
done
sleep 2
capture off

set_surface "$surface" true
sleep 2
capture on

set_surface "$surface" false

echo "Snapshots are report-only; compare the JSON totals after the app has reached the same idle state."
