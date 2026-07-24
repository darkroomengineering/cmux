"use strict";

// Sparkle enclosure URLs must be immutable.
//
// The rolling channel reuses a single "rolling" release and overwrites its
// assets on every ship. That made `releases/download/rolling/programa-macos.dmg`
// a MUTABLE url carrying a CONTENT-BOUND EdDSA signature: a client that read
// appcast N+1 but was served the still-cached DMG N failed validation with
// SUSparkleErrorDomain 4005 ("update is improperly signed"). Observed in
// production on 2026-07-24.
//
// Fix: the appcast enclosure points at a per-build filename that is never
// rewritten, so a given url always returns the exact bytes its signature was
// computed over. `programa-macos.dmg` is still published unversioned for the
// README download button, but Sparkle never reads it.

const ENCLOSURE_PREFIX = "programa-macos-";
const ENCLOSURE_SUFFIX = ".dmg";
const STABLE_DMG_NAME = "programa-macos.dmg";
// Deleting an enclosure turns its url — which the whole design promises is immutable —
// into a 404 for anyone holding an older appcast. That is a milder failure than a
// signature mismatch (Sparkle reports a download error and recovers on the next check,
// rather than declaring the update corrupt), but it is still a failed update, so the
// window is sized to make it rare rather than merely unlikely. At several ships a day,
// 20 builds is roughly a week of headroom for ~420MB of release storage. Raise this
// before lowering it: storage is cheap, a failed auto-update is not.
const DEFAULT_KEEP_BUILDS = 20;

function enclosureFilename(build) {
  const normalized = String(build);
  if (!/^\d+$/.test(normalized)) {
    throw new Error(`Sparkle build number must be digits, got: ${build}`);
  }
  return `${ENCLOSURE_PREFIX}${normalized}${ENCLOSURE_SUFFIX}`;
}

function parseBuildFromEnclosure(assetName) {
  if (typeof assetName !== "string") return null;
  if (!assetName.startsWith(ENCLOSURE_PREFIX) || !assetName.endsWith(ENCLOSURE_SUFFIX)) {
    return null;
  }
  const build = assetName.slice(ENCLOSURE_PREFIX.length, assetName.length - ENCLOSURE_SUFFIX.length);
  if (!/^\d+$/.test(build)) return null;
  return build;
}

// Versioned DMGs accumulate on the reused rolling release (~21MB per ship, several
// ships a day), so old ones are pruned. Anything still referenced by a client that
// is mid-download could 404, hence keeping a few builds of headroom rather than one.
function selectStaleEnclosureAssets({ assetNames, keepBuilds = DEFAULT_KEEP_BUILDS, currentBuild = null }) {
  // An explicit 0 means "keep as few as possible", not "use the default" — so only a
  // missing/unparseable value falls back, and the floor of 1 keeps the shipping build.
  const requestedKeep = Number(keepBuilds);
  const keepCount = Number.isFinite(requestedKeep) ? Math.max(1, requestedKeep) : DEFAULT_KEEP_BUILDS;

  const versioned = [];
  for (const name of assetNames || []) {
    const build = parseBuildFromEnclosure(name);
    if (build !== null) versioned.push({ name, build: BigInt(build) });
  }

  versioned.sort((a, b) => (a.build === b.build ? 0 : a.build > b.build ? -1 : 1));

  const keep = new Set();
  if (currentBuild !== null && currentBuild !== undefined) {
    keep.add(enclosureFilename(currentBuild));
  }
  for (const entry of versioned) {
    if (keep.size >= keepCount) break;
    keep.add(entry.name);
  }

  return versioned.filter((entry) => !keep.has(entry.name)).map((entry) => entry.name);
}

// CLI so release.yml derives the filename from this module instead of rebuilding the
// naming scheme in shell. Two copies of the scheme would drift, and a drifted name is
// exactly the 4005 failure this file exists to prevent.
//
//   node scripts/sparkle_enclosure.js name <build>
//   node scripts/sparkle_enclosure.js prune --current <build> [--keep N] < asset-names
//
// `prune` reads one asset name per line on stdin and prints the stale ones.
function main(argv) {
  const [command, ...rest] = argv;

  if (command === "name") {
    if (rest.length !== 1) throw new Error("Usage: sparkle_enclosure.js name <build>");
    return enclosureFilename(rest[0]);
  }

  if (command === "prune") {
    let keepBuilds = DEFAULT_KEEP_BUILDS;
    let currentBuild = null;
    for (let i = 0; i < rest.length; i += 2) {
      const value = rest[i + 1];
      if (value === undefined) throw new Error(`Missing value for ${rest[i]}`);
      if (rest[i] === "--keep") keepBuilds = value;
      else if (rest[i] === "--current") currentBuild = value;
      else throw new Error(`Unknown flag: ${rest[i]}`);
    }
    const assetNames = require("node:fs")
      .readFileSync(0, "utf8")
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
    return selectStaleEnclosureAssets({ assetNames, keepBuilds, currentBuild }).join("\n");
  }

  throw new Error(`Unknown command: ${command ?? "(none)"}. Expected "name" or "prune".`);
}

if (require.main === module) {
  try {
    const output = main(process.argv.slice(2));
    if (output) process.stdout.write(`${output}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  }
}

module.exports = {
  DEFAULT_KEEP_BUILDS,
  ENCLOSURE_PREFIX,
  ENCLOSURE_SUFFIX,
  STABLE_DMG_NAME,
  enclosureFilename,
  main,
  parseBuildFromEnclosure,
  selectStaleEnclosureAssets,
};
