"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  IMMUTABLE_RELEASE_ASSETS,
  RELEASE_ASSET_GUARD_STATE,
  evaluateReleaseAssetGuard,
  enclosureAssetFromAppcast,
} = require("./release_asset_guard");

test("marks guard as complete and skips build/upload when all immutable assets already exist", () => {
  const result = evaluateReleaseAssetGuard({
    existingAssetNames: [...IMMUTABLE_RELEASE_ASSETS, "notes.txt"],
  });

  assert.deepEqual(result.conflicts, IMMUTABLE_RELEASE_ASSETS);
  assert.deepEqual(result.missingImmutableAssets, []);
  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.COMPLETE);
  assert.equal(result.hasPartialConflict, false);
  assert.equal(result.shouldSkipBuildAndUpload, true);
  assert.equal(result.shouldSkipUpload, true);
});

test("marks guard as clear when immutable assets are not present", () => {
  const result = evaluateReleaseAssetGuard({
    existingAssetNames: ["notes.txt", "checksums.txt"],
  });

  assert.deepEqual(result.conflicts, []);
  assert.deepEqual(result.missingImmutableAssets, IMMUTABLE_RELEASE_ASSETS);
  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.CLEAR);
  assert.equal(result.hasPartialConflict, false);
  assert.equal(result.shouldSkipBuildAndUpload, false);
  assert.equal(result.shouldSkipUpload, false);
});

test("marks guard as partial when only some immutable assets exist", () => {
  const partialAssets = ["appcast.xml", "programad-remote-manifest.json"];
  const result = evaluateReleaseAssetGuard({
    existingAssetNames: partialAssets,
  });

  assert.deepEqual(result.conflicts, partialAssets);
  assert.deepEqual(
    result.missingImmutableAssets,
    IMMUTABLE_RELEASE_ASSETS.filter((assetName) => !partialAssets.includes(assetName)),
  );
  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.PARTIAL);
  assert.equal(result.hasPartialConflict, true);
  assert.equal(result.shouldSkipBuildAndUpload, false);
  assert.equal(result.shouldSkipUpload, false);
});

test("enclosureAssetFromAppcast extracts the per-build DMG name from a realistic appcast enclosure", () => {
  const appcastXml = `<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <title>Version 0.16.0</title>
      <enclosure
        url="https://github.com/darkroomengineering/programa/releases/download/rolling/programa-macos-3011825278401.dmg"
        sparkle:version="3011825278401"
        sparkle:edSignature="abc123=="
        length="123456789"
        type="application/octet-stream"
      />
    </item>
  </channel>
</rss>`;

  assert.equal(enclosureAssetFromAppcast(appcastXml), "programa-macos-3011825278401.dmg");
});

test("enclosureAssetFromAppcast returns null for the unversioned rolling dmg name", () => {
  const appcastXml =
    '<enclosure url="https://github.com/darkroomengineering/programa/releases/download/rolling/programa-macos.dmg" />';

  assert.equal(enclosureAssetFromAppcast(appcastXml), null);
});

test("enclosureAssetFromAppcast returns null for non-string input", () => {
  assert.equal(enclosureAssetFromAppcast(null), null);
  assert.equal(enclosureAssetFromAppcast(undefined), null);
});

test("enclosureAssetFromAppcast returns null when the appcast has no enclosure url at all", () => {
  const appcastXml = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <channel>
    <item>
      <title>Version 0.16.0</title>
    </item>
  </channel>
</rss>`;

  assert.equal(enclosureAssetFromAppcast(appcastXml), null);
});

test("marks guard as partial when the appcast points at a per-build dmg that was never uploaded", () => {
  // Regression for SUSparkleErrorDomain 4005: every static immutable asset is present,
  // which used to be enough to call the release "complete" and skip the rebuild — even
  // though the published appcast names a versioned DMG that doesn't exist on the release,
  // so Sparkle clients would fetch a 404 (or a stale cached DMG) and fail signature checks.
  const appcastXml =
    '<enclosure url="https://github.com/darkroomengineering/programa/releases/download/rolling/programa-macos-500.dmg" />';

  const result = evaluateReleaseAssetGuard({
    existingAssetNames: [...IMMUTABLE_RELEASE_ASSETS, "notes.txt"],
    appcastXml,
  });

  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.PARTIAL);
  assert.equal(result.hasPartialConflict, true);
  assert.equal(result.shouldSkipBuildAndUpload, false);
  assert.ok(result.missingImmutableAssets.includes("programa-macos-500.dmg"));
});

test("marks guard as complete only once the appcast-named per-build dmg is also uploaded", () => {
  const appcastXml =
    '<enclosure url="https://github.com/darkroomengineering/programa/releases/download/rolling/programa-macos-500.dmg" />';

  const result = evaluateReleaseAssetGuard({
    existingAssetNames: [...IMMUTABLE_RELEASE_ASSETS, "programa-macos-500.dmg", "notes.txt"],
    appcastXml,
  });

  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.COMPLETE);
  assert.equal(result.shouldSkipBuildAndUpload, true);
  assert.deepEqual(result.missingImmutableAssets, []);
});

test("evaluateReleaseAssetGuard without appcastXml behaves exactly as before (backward compatibility)", () => {
  const result = evaluateReleaseAssetGuard({
    existingAssetNames: [...IMMUTABLE_RELEASE_ASSETS, "notes.txt"],
  });

  assert.deepEqual(result.conflicts, IMMUTABLE_RELEASE_ASSETS);
  assert.deepEqual(result.missingImmutableAssets, []);
  assert.equal(result.guardState, RELEASE_ASSET_GUARD_STATE.COMPLETE);
  assert.equal(result.shouldSkipBuildAndUpload, true);
});

test("enclosureAssetFromAppcast ignores a versioned dmg url outside the enclosure element", () => {
  // A release-notes link naming a dmg must not satisfy the guard — only the actual
  // <enclosure> tells us what Sparkle will download and verify.
  const appcastXml = [
    "<item>",
    '  <sparkle:releaseNotesLink>https://example.com/notes/programa-macos-500.dmg</sparkle:releaseNotesLink>',
    '  <link url="https://github.com/darkroomengineering/programa/releases/download/rolling/programa-macos-500.dmg" />',
    "</item>",
  ].join("\n");

  assert.equal(enclosureAssetFromAppcast(appcastXml), null);
});
