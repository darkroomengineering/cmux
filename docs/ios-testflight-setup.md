# Getting the iOS companion onto TestFlight

One-time setup. The CI lane (`.github/workflows/ios-testflight.yml`) is already
written, verified, and currently skipping every run because the Apple signing
material is not on the repo. Everything below is the human/portal half.

Tracked in [#203](https://github.com/darkroomengineering/programa/issues/203).

---

## Before starting: two facts to check

**Team ID must be `ZNHHMX2RP6`.** It is hardcoded at
`.github/workflows/ios-testflight.yml:189`. If the Apple Developer account you
are signed into is a different team, stop — nothing below will work, and the
workflow needs editing first.

**These three identifiers already exist and must NOT be deleted:**

| identifier | what it is |
|---|---|
| `com.darkroom.programa` | the shipping macOS app |
| `com.darkroom.programa.spike` | the iOS companion |
| `com.darkroom.programa.spike.widgets` | the widget extension |

---

## Who does what

**An agent driving the browser can do:** steps 1, 2, 4, 6.

**A human must do:** steps 3, 5, 7 — they involve a certificate private key, a
`.p12` export password, and an App Store Connect API key. Do not route
credentials, passwords, or key files through an agent. Download them yourself
and paste the secrets into GitHub yourself.

---

## 1. Confirm the iCloud container exists

<https://developer.apple.com/account/resources/identifiers/list/cloudContainer>

Look for **`iCloud.com.darkroom.programa`**.

If it is missing, create it here with exactly that identifier. Xcode cannot
create it later: automatic signing refuses to make a container whose name does
not match the bundle id, so `-allowProvisioningUpdates` will not do it
(`ios/ProgramaSpike/project.yml:114-117`).

## 2. Set capabilities on the App IDs

<https://developer.apple.com/account/resources/identifiers/list>

### `com.darkroom.programa.spike` — listed as "XC com darkroom programa spike"

Enable **both**:

- **Push Notifications**
- **iCloud** → Configure → tick **CloudKit** → assign container
  `iCloud.com.darkroom.programa`

Save.

Why push matters: without it the signed build gets
`aps-environment = development`, and `scripts/build-ios-testflight.sh:110-117`
hard-fails rather than uploading a build that would silently receive no
notifications. At runtime the symptom is `NSCocoaErrorDomain 3000 "no valid
aps-environment entitlement string found for application"`.

### `com.darkroom.programa` — listed as "Programa"

**Verify only.** Confirm **iCloud** is enabled and assigned the *same* container
`iCloud.com.darkroom.programa`. The container must be on both App IDs — the Mac
writes the records, the phone reads them
(`ios/ProgramaSpike/project.yml:110-113`). If it is already set, change nothing.

### `com.darkroom.programa.spike.widgets`

**Nothing to do.** The widget target declares no entitlements at all
(`ios/ProgramaSpike/project.yml:120-145`) — no push, no iCloud.

## 3. Get an Apple Distribution certificate — human

<https://developer.apple.com/account/resources/certificates/list>

Type must be **Apple Distribution**. A Developer ID or Apple Development
certificate is rejected outright by `scripts/build-ios-testflight.sh:66-73`.

1. Create or download the certificate, double-click the `.cer` to install it
2. Open **Keychain Access** → My Certificates → right-click it → **Export**
3. Save as `.p12` and set an export password — keep that password, it becomes
   `APPLE_IOS_DIST_CERT_PASSWORD`

## 4. Mint two App Store provisioning profiles

<https://developer.apple.com/account/resources/profiles/list>

**Create new ones. Do not reuse the existing profiles** — they were minted
before the iCloud container was attached to the App ID, so they carry no
containers (`plans/golden-tumbling-gray.md:490-493`). A profile bakes in
whatever capabilities exist at creation time, which is why step 2 has to come
first.

Create both as type **App Store** (distribution), signed with the certificate
from step 3:

| App ID | file it produces |
|---|---|
| `com.darkroom.programa.spike` | app `.mobileprovision` |
| `com.darkroom.programa.spike.widgets` | widget `.mobileprovision` |

Download both.

## 5. Create the App Store Connect app record and API key — human

### App record

<https://appstoreconnect.apple.com/apps> → **+** → **New App**

- Platform: **iOS**
- Bundle ID: **`com.darkroom.programa.spike`**
- Name and SKU: your choice

**This step is easy to miss.** Nothing in the repo creates this record, it is
not in the issue's secret table, and `altool` rejects the upload without it.

### API key

<https://appstoreconnect.apple.com/access/integrations/api>

**+** → access role **App Manager** → download the `.p8`.

The `.p8` is downloadable exactly once. Note the **Key ID** and **Issuer ID**
shown on that page.

## 6. Add all seven repository secrets — human

<https://github.com/darkroomengineering/programa/settings/secrets/actions>

Encode the file-based ones:

```bash
base64 -i dist.p12               | pbcopy   # APPLE_IOS_DIST_CERT_BASE64
base64 -i app.mobileprovision    | pbcopy   # APPLE_IOS_APP_PROFILE_BASE64
base64 -i widget.mobileprovision | pbcopy   # APPLE_IOS_WIDGET_PROFILE_BASE64
base64 -i AuthKey_XXXXXXXXXX.p8  | pbcopy   # APPSTORE_CONNECT_KEY_P8_BASE64
```

| secret | value |
|---|---|
| `APPLE_IOS_DIST_CERT_BASE64` | base64 of the `.p12` from step 3 |
| `APPLE_IOS_DIST_CERT_PASSWORD` | the `.p12` export password, plain text |
| `APPLE_IOS_APP_PROFILE_BASE64` | base64 of the app `.mobileprovision` |
| `APPLE_IOS_WIDGET_PROFILE_BASE64` | base64 of the widget `.mobileprovision` |
| `APPSTORE_CONNECT_KEY_ID` | Key ID, plain text |
| `APPSTORE_CONNECT_ISSUER_ID` | Issuer ID, plain text |
| `APPSTORE_CONNECT_KEY_P8_BASE64` | base64 of the `.p8` |

Add all seven. A partial set fails fast and names what is missing, but it still
costs a cycle.

## 7. Dry run

```bash
gh workflow run ios-testflight.yml -f upload=false
gh run watch --repo darkroomengineering/programa
```

Success looks like: the `build` job no longer skipped, and the
"Verifying signed entitlements" step printing all three of

```
ok aps-environment = production
ok get-task-allow = false
ok com.apple.developer.icloud-container-environment = Production
```

## 8. Ship

Push any change under `ios/**` to `main`. The upload runs automatically. The
build appears in App Store Connect after processing (usually 5-15 minutes), then
can be assigned to testers.

---

## If step 7 fails

The failure message names which check failed.

| message | cause | fix |
|---|---|---|
| `No 'Apple Distribution' identity found` | wrong certificate type | redo step 3 with an Apple Distribution cert |
| `aps-environment='development'` (or absent) | Push was not enabled on the App ID when the profile was minted | redo step 2, then re-mint in step 4 |
| `com.apple.developer.icloud-container-environment` not `Production` | profile predates the container | redo step 4 |
| missing `APPSTORE_CONNECT_*` at preflight | upload credentials absent | finish step 6 |
| `altool` rejects the upload | no App Store Connect app record | do step 5 |

Note the difference in behaviour by trigger: a **push** with missing secrets
warns and skips so `main` stays green; a **`workflow_dispatch`** with missing
secrets fails hard.

---

## Notes

- **Signing state is temporary.** `scripts/build-ios-testflight.sh` uses a unique build
  keychain, appends it to the existing user search list, and restores that list on every
  exit. Provisioning profiles and an existing App Store Connect key are likewise restored;
  artifacts created only for the build are removed.
- **Build numbers are already handled.** The lane injects
  `GITHUB_RUN_ID` + attempt as `CURRENT_PROJECT_VERSION`
  (`.github/workflows/ios-testflight.yml:170-174`), overriding the static `"1"`
  committed in `project.yml`. No duplicate-build rejection on later uploads.
- **Already verified present and correct**, so no action needed:
  `ITSAppUsesNonExemptEncryption`, `NSCameraUsageDescription` (the QR scanner),
  `NSLocalNetworkUsageDescription`, the iPad orientation keys the build script
  pre-checks, the 1024px app icon, and `PrivacyInfo.xcprivacy`.
- **Non-blocking gap:** the widget target has no `PrivacyInfo.xcprivacy` of its
  own. This will not block a first upload or internal testing, but if the widget
  touches a required-reason API it can surface as an ITMS warning and matters
  before external testing or review.
- **Bundle id stays `com.darkroom.programa.spike`.** Renaming means a new App
  ID, a new App Store Connect record, and re-attaching the iCloud container.
  Testers only ever see the display name "Programa".

## Rules for an agent doing the portal steps

- **Do not delete any identifier, certificate, profile, or container.** Deletion
  is irreversible and invalidates everything signed against it.
- **Do not modify identifiers other than the two named in step 2**, and on
  `com.darkroom.programa` only verify — do not change it.
- **Do not handle credentials.** Steps 3, 5, and 6 involve a private key, an
  export password, and API keys. Leave those to a human.
- **Stop and report** if an identifier is missing, if the team is not
  `ZNHHMX2RP6`, or if a capability cannot be enabled — do not improvise around
  it.
