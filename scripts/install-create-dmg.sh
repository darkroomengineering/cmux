#!/usr/bin/env bash
set -euo pipefail

VERSION="${CREATE_DMG_VERSION:-}"
BUN_COMMAND="${PROGRAMA_BUN_COMMAND:-bun}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SCRIPT_DIR}/create-dmg"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  echo "CREATE_DMG_VERSION must be an explicit version (for example, 8.0.0)" >&2
  exit 1
fi

node - "${INSTALL_DIR}/package.json" "${INSTALL_DIR}/bun.lock" "${VERSION}" <<'NODE'
"use strict";
const fs = require("node:fs");
const [packagePath, lockPath, expectedVersion] = process.argv.slice(2);
const packageJson = JSON.parse(fs.readFileSync(packagePath, "utf8"));
if (packageJson.dependencies?.["create-dmg"] !== expectedVersion) {
  throw new Error(`CREATE_DMG_VERSION ${expectedVersion} does not match the locked package version`);
}
const lock = fs.readFileSync(lockPath, "utf8");
if (!lock.includes(`create-dmg@${expectedVersion}`) || !/sha512-[A-Za-z0-9+/]+={0,2}/.test(lock)) {
  throw new Error("create-dmg bun.lock is missing its exact version or integrity metadata");
}
NODE

command -v "${BUN_COMMAND}" >/dev/null 2>&1 || {
  echo "Bun command is unavailable: ${BUN_COMMAND}" >&2
  exit 1
}

"${BUN_COMMAND}" install \
  --cwd "${INSTALL_DIR}" \
  --frozen-lockfile \
  --ignore-scripts

LOCAL_BIN="${INSTALL_DIR}/node_modules/.bin"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "${LOCAL_BIN}" >> "${GITHUB_PATH}"
fi
echo "create-dmg local bin: ${LOCAL_BIN}"
