"use strict";

const { buildsFromAppcast } = require("./rolling_release_state");

const CANONICAL_BUILD = /^[1-9][0-9]*$/;

function assertCanonicalBuild(build, label) {
  if (typeof build !== "string" || !CANONICAL_BUILD.test(build)) {
    throw new TypeError(`${label} must be a canonical positive decimal build string`);
  }
}

function decodeAssetBytes(data) {
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString("utf8");
  if (ArrayBuffer.isView(data)) {
    return Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString("utf8");
  }
  throw new TypeError("appcast asset download did not return bytes");
}

async function enforceSparkleMonotonicBuild({ github, owner, repo, effectiveBuild }) {
  assertCanonicalBuild(effectiveBuild, "effective build");
  if (
    github === null ||
    typeof github !== "object" ||
    typeof github.rest?.repos?.listReleases !== "function" ||
    typeof github.paginate?.iterator !== "function" ||
    typeof github.rest?.repos?.getReleaseAsset !== "function"
  ) {
    throw new TypeError("github must be an authenticated Octokit-compatible client");
  }
  if (typeof owner !== "string" || owner === "" || typeof repo !== "string" || repo === "") {
    throw new TypeError("owner and repo are required");
  }

  const publishedBuilds = [];
  let advertisedAppcastCount = 0;
  const pages = github.paginate.iterator(github.rest.repos.listReleases, {
    owner,
    repo,
    per_page: 100,
  });
  for await (const page of pages) {
    if (!Array.isArray(page?.data)) throw new TypeError("release enumeration returned invalid data");
    for (const release of page.data) {
      const tag = release?.tag_name;
      if (release?.draft === true) continue;
      if (release?.draft !== false) {
        throw new TypeError(`release ${String(tag)} has an invalid draft state`);
      }
      if (!Array.isArray(release.assets)) {
        throw new TypeError(`published release ${tag} assets are unavailable`);
      }
      const appcasts = release.assets.filter((asset) => asset?.name === "appcast.xml");
      if (appcasts.length === 0) continue;
      if (appcasts.length !== 1) {
        throw new TypeError(`published release ${tag} must contain at most one appcast.xml asset`);
      }
      advertisedAppcastCount += 1;
      const appcast = appcasts[0];
      if (!Number.isSafeInteger(appcast.id) || appcast.id <= 0) {
        throw new TypeError(`authoritative release ${tag} appcast asset id is invalid`);
      }
      const response = await github.rest.repos.getReleaseAsset({
        owner,
        repo,
        asset_id: appcast.id,
        headers: { accept: "application/octet-stream" },
      });
      const xml = decodeAssetBytes(response?.data);
      publishedBuilds.push(...buildsFromAppcast(xml, `${tag} appcast`));
    }
  }

  if (advertisedAppcastCount === 0) return;
  if (publishedBuilds.length === 0) {
    throw new TypeError("authoritative releases contain no published Sparkle builds");
  }
  let publishedHighWater = publishedBuilds[0];
  for (const build of publishedBuilds.slice(1)) {
    if (BigInt(build) > BigInt(publishedHighWater)) publishedHighWater = build;
  }
  if (BigInt(effectiveBuild) <= BigInt(publishedHighWater)) {
    throw new RangeError(
      `effective build ${effectiveBuild} must be greater than published build ${publishedHighWater}`,
    );
  }
}

module.exports = { enforceSparkleMonotonicBuild };
