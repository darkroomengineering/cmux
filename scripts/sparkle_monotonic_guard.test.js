"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

// Public contract for scripts/sparkle_monotonic_guard.js:
//
//   await enforceSparkleMonotonicBuild({ github, owner, repo, effectiveBuild })
//
// The authenticated Octokit client is paginated through
// `github.paginate.iterator(github.rest.repos.listReleases, ...)`. Every
// published, non-draft release that advertises appcast.xml is authoritative,
// regardless of its tag. The guard downloads and parses each advertised appcast,
// rejects incomplete or ambiguous release state, and compares the candidate
// against the BigInt maximum. Drafts and releases without appcasts are ignored.
// Bootstrap succeeds only when no authoritative advertised appcast exists.
const { enforceSparkleMonotonicBuild } = require("./sparkle_monotonic_guard");

const OWNER = "darkroomengineering";
const REPO = "programa";
const VALID_ED25519_SIGNATURE = Buffer.alloc(64, 1).toString("base64");

function appcast(build, enclosureBuild = build, namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle") {
  return `<?xml version="1.0" encoding="utf-8"?>
    <rss xmlns:sparkle="${namespace}" version="2.0"><channel><item>
      <sparkle:version>${build}</sparkle:version>
      <enclosure url="https://github.com/${OWNER}/${REPO}/releases/download/rolling/programa-macos-${enclosureBuild}.dmg" length="902" sparkle:edSignature="${VALID_ED25519_SIGNATURE}" />
    </item></channel></rss>`;
}

function legacyAppcast(build) {
  return `<?xml version="1.0" encoding="utf-8"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item>
      <sparkle:version>${build}</sparkle:version>
      <enclosure url="https://github.com/${OWNER}/${REPO}/releases/download/v0.1.0/programa-macos.dmg" length="902" sparkle:edSignature="${VALID_ED25519_SIGNATURE}" />
    </item></channel></rss>`;
}

function legacyAttributeAppcast(build, enclosureBuild = build) {
  return `<?xml version="1.0" encoding="utf-8"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item>
      <enclosure url="https://github.com/${OWNER}/${REPO}/releases/download/v0.1.0/programa-macos-${enclosureBuild}.dmg" length="902" sparkle:edSignature="${VALID_ED25519_SIGNATURE}" sparkle:version="${build}" />
    </item></channel></rss>`;
}

function octokitDownload(xml) {
  const bytes = new TextEncoder().encode(xml);
  return { data: bytes.buffer, status: 200 };
}

function apiError(message, status) {
  const error = new Error(message);
  if (status !== undefined) error.status = status;
  return error;
}

function release(tag, assetId, { draft = false, assets, xml = appcast(String(assetId)) } = {}) {
  return {
    release: {
      id: assetId + 1000,
      tag_name: tag,
      draft,
      assets: assets ?? [{ id: assetId, name: "appcast.xml" }],
    },
    xml,
  };
}

function githubWith({ pages = [], listError, downloadErrors = new Map() } = {}) {
  const xmlByAsset = new Map();
  const normalizedPages = pages.map((page) => page.map((entry) => {
    if (entry.xml !== undefined) {
      for (const asset of entry.release.assets) {
        if (asset.name === "appcast.xml") xmlByAsset.set(asset.id, entry.xml);
      }
    }
    return entry.release;
  }));
  const downloaded = [];
  let pagesRead = 0;
  const listReleases = async () => { throw new Error("listReleases must be consumed through pagination"); };
  const github = {
    rest: { repos: {
      listReleases,
      async getReleaseAsset({ owner, repo, asset_id: assetId, headers }) {
        assert.equal(owner, OWNER);
        assert.equal(repo, REPO);
        assert.equal(headers?.accept, "application/octet-stream");
        downloaded.push(assetId);
        if (downloadErrors.has(assetId)) throw downloadErrors.get(assetId);
        if (!xmlByAsset.has(assetId)) throw apiError("asset unavailable", 404);
        return octokitDownload(xmlByAsset.get(assetId));
      },
    } },
    paginate: {
      async *iterator(route, params) {
        assert.equal(route, listReleases);
        assert.deepEqual(params, { owner: OWNER, repo: REPO, per_page: 100 });
        if (listError) throw listError;
        for (const page of normalizedPages) {
          pagesRead += 1;
          yield { data: page };
        }
      },
    },
  };
  return { github, downloaded, get pagesRead() { return pagesRead; } };
}

function enforce(client, effectiveBuild) {
  return enforceSparkleMonotonicBuild({ github: client.github, owner: OWNER, repo: REPO, effectiveBuild });
}

test("empty public release state bootstraps the first Sparkle publication", async () => {
  const client = githubWith({ pages: [[]] });
  await assert.doesNotReject(enforce(client, "1"));
  assert.deepEqual(client.downloaded, []);
});

test("drafts and non-draft releases without appcasts do not create authoritative public state", async () => {
  const client = githubWith({ pages: [[
    release("rolling-candidate-99", 99),
    release("nightly", 100, { assets: [{ id: 100, name: "programa-macos.dmg" }] }),
    release("v01.2.3", 102, { assets: [] }),
    release("v1.2.3", 101, { draft: true }),
  ]] });
  await assert.doesNotReject(enforce(client, "1"));
  assert.deepEqual(client.downloaded, []);
});

test("an arbitrary published tag with an appcast contributes to the maximum", async () => {
  const higher = "900719925474099312345678901234567899";
  const client = githubWith({ pages: [[
    release("rolling", 10, { xml: appcast("41") }),
    release("customer-preview-2026", 11, { xml: appcast(higher) }),
  ]] });
  await assert.rejects(enforce(client, higher), /greater|published|build|monotonic/i);
  assert.deepEqual(client.downloaded, [10, 11]);
});

test("all pages and authoritative releases contribute to the BigInt maximum", async () => {
  const huge = "900719925474099312345678901234567890";
  const client = githubWith({ pages: [
    [release("rolling", 10, { xml: appcast("41") }), release("preview", 11, { xml: appcast("999") })],
    [release("v0.1.0", 12, { xml: appcast(huge) }), release("v9.0.0", 13, { draft: true, xml: appcast(`${huge}9`) })],
  ] });
  await assert.doesNotReject(enforce(client, (BigInt(huge) + 1n).toString()));
  assert.equal(client.pagesRead, 2);
  assert.deepEqual(client.downloaded, [10, 11, 12]);
});

test("legacy milestone stable-DMG appcasts remain monotonic high-water evidence", async () => {
  const published = "900719925474099312345678901234567899";
  const client = githubWith({ pages: [[release("v0.1.0", 10, { xml: legacyAppcast(published) })]] });
  await assert.rejects(enforce(client, published), /greater|published|build|monotonic/i);
  assert.deepEqual(client.downloaded, [10]);
});

test("official attribute-era appcasts remain monotonic high-water evidence", async () => {
  const published = "900719925474099312345678901234567899";
  const client = githubWith({ pages: [[release("legacy-channel", 10, { xml: legacyAttributeAppcast(published) })]] });
  await assert.rejects(enforce(client, published), /greater|published|build|monotonic/i);
});

test("an equal or lower candidate cannot pass the maximum from any page", async () => {
  const client = githubWith({ pages: [
    [release("rolling", 10, { xml: appcast("41") })],
    [release("v1.0.0", 11, { xml: appcast("900719925474099312345678901234567899") })],
  ] });
  await assert.rejects(enforce(client, "900719925474099312345678901234567899"), /greater|published|build|monotonic/i);
});

test("release enumeration failures cannot silently disable downgrade protection", async () => {
  for (const error of [apiError("server", 500), apiError("rate limit", 403), new Error("network")]) {
    const client = githubWith({ listError: error });
    await assert.rejects(enforce(client, "2"));
  }
});

test("every advertised appcast is unique and readable", async (t) => {
  await t.test("missing appcast is ignored", async () => {
    const client = githubWith({ pages: [[release("rolling", 10, { assets: [{ id: 9, name: "programa-macos.dmg" }] })]] });
    await assert.doesNotReject(enforce(client, "42"));
    assert.deepEqual(client.downloaded, []);
  });
  await t.test("duplicate appcast", async () => {
    const client = githubWith({ pages: [[release("rolling", 10, { assets: [
      { id: 10, name: "appcast.xml" }, { id: 11, name: "appcast.xml" },
    ] })]] });
    await assert.rejects(enforce(client, "42"), /appcast|duplicate|exactly/i);
  });
  await t.test("unreadable appcast", async () => {
    const client = githubWith({
      pages: [[release("rolling", 10)]],
      downloadErrors: new Map([[10, apiError("unavailable", 503)]]),
    });
    await assert.rejects(enforce(client, "42"), /unavailable|503|appcast/i);
  });
  await t.test("malformed appcast", async () => {
    const client = githubWith({ pages: [[release("rolling", 10, { xml: "<rss><channel><item>" })]] });
    await assert.rejects(enforce(client, "42"), /xml|appcast|malformed|unclosed/i);
  });
});

test("Sparkle fields require the canonical namespace URI", async (t) => {
  for (const [name, xml] of [
    ["missing", appcast("41").replace(' xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"', "")],
    ["wrong", appcast("41", "41", "urn:not-sparkle")],
  ]) {
    await t.test(name, async () => {
      const client = githubWith({ pages: [[release("rolling", 10, { xml })]] });
      await assert.rejects(enforce(client, "42"), /namespace|xmlns|sparkle|appcast/i);
    });
  }
});

test("one item must pair one canonical child version with one matching enclosure", async (t) => {
  const feed = (item) => `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>${item}</channel></rss>`;
  const enclosure = (build) => `<enclosure url="https://github.com/${OWNER}/${REPO}/releases/download/rolling/programa-macos-${build}.dmg" length="902" sparkle:edSignature="${VALID_ED25519_SIGNATURE}" />`;
  const cases = [
    ["missing version", `<item>${enclosure("41")}</item>`],
    ["duplicate versions", `<item><sparkle:version>41</sparkle:version><sparkle:version>41</sparkle:version>${enclosure("41")}</item>`],
    ["duplicate enclosures", `<item><sparkle:version>41</sparkle:version>${enclosure("41")}${enclosure("41")}</item>`],
    ["mismatched build", `<item><sparkle:version>41</sparkle:version>${enclosure("42")}</item>`],
    ["noncanonical version", `<item><sparkle:version>0041</sparkle:version>${enclosure("0041")}</item>`],
  ];
  for (const [name, item] of cases) {
    await t.test(name, async () => {
      const client = githubWith({ pages: [[release("rolling", 10, { xml: feed(item) })]] });
      await assert.rejects(enforce(client, "42"), /appcast|item|version|enclosure|canonical|match/i);
    });
  }
});

test("attribute-era versions reject duplicate or indirect version sources", async (t) => {
  const feed = (item) => `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>${item}</channel></rss>`;
  const baseAttributes = `url="https://github.com/${OWNER}/${REPO}/releases/download/v0.1.0/programa-macos-41.dmg" length="902" sparkle:edSignature="${VALID_ED25519_SIGNATURE}"`;
  const cases = [
    ["child and matching attribute", `<item><sparkle:version>41</sparkle:version><enclosure ${baseAttributes} sparkle:version="41" /></item>`],
    ["child and disagreeing attribute", `<item><sparkle:version>41</sparkle:version><enclosure ${baseAttributes} sparkle:version="42" /></item>`],
    ["duplicate attributes", `<item><enclosure ${baseAttributes} sparkle:version="41" sparkle:version="41" /></item>`],
    ["attribute on item", `<item sparkle:version="41"><enclosure ${baseAttributes} /></item>`],
    ["nested enclosure", `<item><group><enclosure ${baseAttributes} sparkle:version="41" /></group></item>`],
  ];
  for (const [name, item] of cases) {
    await t.test(name, async () => {
      const client = githubWith({ pages: [[release("legacy-channel", 10, { xml: feed(item) })]] });
      await assert.rejects(enforce(client, "42"), /appcast|version|duplicate|direct|item|enclosure|ambiguous/i);
    });
  }
});

test("effective builds are canonical positive decimal strings", async () => {
  for (const effectiveBuild of ["0", "01", "+1", "1e3", 42]) {
    const client = githubWith({ pages: [[]] });
    await assert.rejects(enforce(client, effectiveBuild), /build|canonical|decimal/i);
  }
});
