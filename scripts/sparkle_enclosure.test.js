"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const path = require("node:path");

const {
  STABLE_DMG_NAME,
  enclosureFilename,
  parseBuildFromEnclosure,
  selectStaleEnclosureAssets,
} = require("./sparkle_enclosure");

const SCRIPT = path.join(__dirname, "sparkle_enclosure.js");

// Exercise the CLI the release workflow actually invokes, not just the exported
// functions — the workflow shells out, so that is the path that can break.
function runCli(args, stdin = "") {
  return execFileSync("node", [SCRIPT, ...args], { input: stdin, encoding: "utf8" }).trim();
}

test("enclosure filename is unique per build so the url never changes content", () => {
  assert.equal(enclosureFilename("3011825278401"), "programa-macos-3011825278401.dmg");
  assert.equal(enclosureFilename(83), "programa-macos-83.dmg");
  assert.notEqual(enclosureFilename("1"), enclosureFilename("2"));
});

test("rejects a build number that is not digits", () => {
  assert.throws(() => enclosureFilename("v0.3.0"), /must be digits/);
  assert.throws(() => enclosureFilename(""), /must be digits/);
});

test("parses the build back out, and ignores the unversioned download-button dmg", () => {
  assert.equal(parseBuildFromEnclosure("programa-macos-3011825278401.dmg"), "3011825278401");
  assert.equal(parseBuildFromEnclosure(STABLE_DMG_NAME), null);
  assert.equal(parseBuildFromEnclosure("appcast.xml"), null);
  assert.equal(parseBuildFromEnclosure("programa-macos-abc.dmg"), null);
  assert.equal(parseBuildFromEnclosure(undefined), null);
});

test("prunes oldest versioned dmgs and keeps the newest builds", () => {
  const stale = selectStaleEnclosureAssets({
    assetNames: [
      "programa-macos-100.dmg",
      "programa-macos-300.dmg",
      "programa-macos-200.dmg",
      "programa-macos-400.dmg",
      "programa-macos-500.dmg",
    ],
    keepBuilds: 3,
  });

  assert.deepEqual(stale.sort(), ["programa-macos-100.dmg", "programa-macos-200.dmg"]);
});

test("never prunes the stable download-button dmg or unrelated assets", () => {
  const stale = selectStaleEnclosureAssets({
    assetNames: [
      STABLE_DMG_NAME,
      "appcast.xml",
      "programa-macos-100.dmg",
      "programa-macos-200.dmg",
      "programa-macos-300.dmg",
      "programa-macos-400.dmg",
    ],
    keepBuilds: 3,
  });

  assert.deepEqual(stale, ["programa-macos-100.dmg"]);
});

test("never prunes the build being shipped right now", () => {
  const stale = selectStaleEnclosureAssets({
    assetNames: [
      "programa-macos-900.dmg",
      "programa-macos-800.dmg",
      "programa-macos-700.dmg",
      "programa-macos-5.dmg",
    ],
    keepBuilds: 1,
    currentBuild: "5",
  });

  assert.ok(!stale.includes("programa-macos-5.dmg"));
  assert.deepEqual(stale.sort(), [
    "programa-macos-700.dmg",
    "programa-macos-800.dmg",
    "programa-macos-900.dmg",
  ]);
});

test("compares build numbers numerically, not lexically", () => {
  // Lexical sort would rank "programa-macos-9.dmg" above the 13-digit run-id builds.
  const stale = selectStaleEnclosureAssets({
    assetNames: [
      "programa-macos-9.dmg",
      "programa-macos-3011825278401.dmg",
      "programa-macos-3011771115001.dmg",
    ],
    keepBuilds: 2,
  });

  assert.deepEqual(stale, ["programa-macos-9.dmg"]);
});

test("keeps run-id builds beyond Number precision distinct", () => {
  const big = "90071992547409931";
  const bigger = "90071992547409932";
  const stale = selectStaleEnclosureAssets({
    assetNames: [enclosureFilename(big), enclosureFilename(bigger)],
    keepBuilds: 1,
  });

  assert.deepEqual(stale, [enclosureFilename(big)]);
});

test("prunes nothing when there is nothing older than the keep window", () => {
  assert.deepEqual(
    selectStaleEnclosureAssets({ assetNames: ["programa-macos-100.dmg"], keepBuilds: 3 }),
    []
  );
  assert.deepEqual(selectStaleEnclosureAssets({ assetNames: [], keepBuilds: 3 }), []);
  assert.deepEqual(selectStaleEnclosureAssets({ assetNames: undefined }), []);
});

test("keeps at least one build even if asked to keep zero", () => {
  const stale = selectStaleEnclosureAssets({
    assetNames: ["programa-macos-100.dmg", "programa-macos-200.dmg"],
    keepBuilds: 0,
  });

  assert.deepEqual(stale, ["programa-macos-100.dmg"]);
});

test("cli prints the enclosure filename the workflow stages and signs", () => {
  assert.equal(runCli(["name", "3011825278401"]), "programa-macos-3011825278401.dmg");
});

test("cli fails loudly on a non-numeric build instead of emitting a bad name", () => {
  assert.throws(() => runCli(["name", "v0.3.0"]), /must be digits/);
  assert.throws(() => runCli(["nope"]), /Unknown command/);
});

test("cli prunes stale enclosures listed on stdin and keeps the shipping build", () => {
  const assets = [
    STABLE_DMG_NAME,
    "appcast.xml",
    "programa-macos-100.dmg",
    "programa-macos-200.dmg",
    "programa-macos-300.dmg",
    "programa-macos-400.dmg",
  ].join("\n");

  const stale = runCli(["prune", "--keep", "2", "--current", "400"], assets).split("\n");

  assert.deepEqual(stale.sort(), ["programa-macos-100.dmg", "programa-macos-200.dmg"]);
});

test("cli prints nothing when there is nothing to prune", () => {
  assert.equal(runCli(["prune", "--current", "100"], "programa-macos-100.dmg"), "");
  assert.equal(runCli(["prune", "--current", "100"], ""), "");
});
