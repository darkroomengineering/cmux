#!/usr/bin/env bash
set -euo pipefail

# Builds, signs and (optionally) uploads the iOS companion app to TestFlight.
#
# Signing is MANUAL here, unlike a local Xcode archive. CI has no authenticated
# Xcode account, so `-allowProvisioningUpdates` cannot create or refresh anything;
# the distribution certificate and both App Store profiles must arrive as
# secrets. That is also why this script derives the profile names from the
# imported profiles at runtime rather than hardcoding them: profile names change
# whenever they are regenerated in the portal, and a stale hardcoded name fails
# the export with an unhelpful error.
#
# Required environment:
#   PROGRAMA_IOS_DIST_CERT_P12       path to the Apple Distribution .p12
#   PROGRAMA_IOS_DIST_CERT_PASSWORD  its password
#   PROGRAMA_IOS_APP_PROFILE         path to the app's App Store .mobileprovision
#   PROGRAMA_IOS_WIDGET_PROFILE      path to the widget's App Store .mobileprovision
#   PROGRAMA_IOS_TEAM_ID             e.g. ZNHHMX2RP6
# Optional:
#   PROGRAMA_IOS_BUILD_NUMBER        CFBundleVersion to stamp (defaults to 1)
#   PROGRAMA_IOS_UPLOAD              set to 1 to upload; otherwise export only
#   PROGRAMA_ASC_KEY_ID / PROGRAMA_ASC_ISSUER_ID / PROGRAMA_ASC_KEY_P8
#                                    App Store Connect API key, required to upload

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="$ROOT_DIR/ios/ProgramaSpike"
WORK_DIR="${PROGRAMA_IOS_WORK_DIR:-$ROOT_DIR/.ios-build}"
ARCHIVE_PATH="$WORK_DIR/ProgramaSpike.xcarchive"
EXPORT_DIR="$WORK_DIR/export"

APP_BUNDLE_ID="com.darkroom.programa.spike"
WIDGET_BUNDLE_ID="com.darkroom.programa.spike.widgets"

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
}

require PROGRAMA_IOS_DIST_CERT_P12
require PROGRAMA_IOS_DIST_CERT_PASSWORD
require PROGRAMA_IOS_APP_PROFILE
require PROGRAMA_IOS_WIDGET_PROFILE
require PROGRAMA_IOS_TEAM_ID

BUILD_NUMBER="${PROGRAMA_IOS_BUILD_NUMBER:-1}"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$EXPORT_DIR"

# ---------------------------------------------------------------- keychain
KEYCHAIN="ios-build.keychain"
KEYCHAIN_PASSWORD="$(uuidgen)"
security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$PROGRAMA_IOS_DIST_CERT_P12" -k "$KEYCHAIN" \
  -P "$PROGRAMA_IOS_DIST_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN"

SIGN_IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
  | grep -oE '"Apple Distribution: [^"]+"' | head -1 | tr -d '"')"
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "No 'Apple Distribution' identity found in the imported certificate." >&2
  echo "A Developer ID or Apple Development cert cannot sign for TestFlight." >&2
  security find-identity -v -p codesigning "$KEYCHAIN" >&2 || true
  exit 1
fi
echo "Signing identity: $SIGN_IDENTITY"

# ------------------------------------------------------- provisioning profiles
# Xcode looks for profiles by UUID filename in this directory (moved here in
# Xcode 16; the old ~/Library/MobileDevice path is no longer consulted).
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$PROFILE_DIR"

# PlistBuddy needs a real, seekable file. Handed /dev/stdin it does not just
# fail: it prints "Error Reading File: /dev/stdin" to STDOUT, so the caller's
# emptiness check sees a non-empty value and treats the error text as the field.
# That produced `cp ... "Error Reading File: /dev/stdin.mobileprovision"` and a
# "No such file or directory" a hundred lines away from the real cause. Decode
# to a temp file instead, and return empty on any failure so the callers'
# `-z` guards work.
profile_field() {
  local src="$1" key="$2" plist
  plist="$(mktemp "${TMPDIR:-/tmp}/programa-profile.XXXXXX")"
  if security cms -D -i "$src" >"$plist" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Print $key" "$plist" 2>/dev/null || true
  fi
  rm -f "$plist"
}

install_profile() {
  local src="$1"
  local uuid name
  uuid="$(profile_field "$src" ":UUID")"
  name="$(profile_field "$src" ":Name")"
  if [[ -z "$uuid" || -z "$name" ]]; then
    echo "Could not read UUID/Name from profile: $src" >&2
    exit 1
  fi
  cp "$src" "$PROFILE_DIR/$uuid.mobileprovision"
  echo "$name"
}

APP_PROFILE_NAME="$(install_profile "$PROGRAMA_IOS_APP_PROFILE")"
WIDGET_PROFILE_NAME="$(install_profile "$PROGRAMA_IOS_WIDGET_PROFILE")"
echo "App profile:    $APP_PROFILE_NAME"
echo "Widget profile: $WIDGET_PROFILE_NAME"

# Fail early and loudly if the app profile does not grant production push. A
# TestFlight build without it installs and runs fine and silently receives no
# CloudKit pushes, which reads as "the companion app is broken" rather than as a
# signing problem. This exact gap was found by hand on the first build: the App
# Store profile predated Push Notifications being enabled on the App ID.
APP_PROFILE_APS="$(profile_field "$PROGRAMA_IOS_APP_PROFILE" ":Entitlements:aps-environment")"
if [[ "$APP_PROFILE_APS" != "production" ]]; then
  echo "" >&2
  echo "FAIL: the app's App Store profile has aps-environment='${APP_PROFILE_APS:-<absent>}'," >&2
  echo "not 'production'. The build would receive no push notifications." >&2
  echo "Regenerate the profile with Push Notifications enabled on App ID $APP_BUNDLE_ID." >&2
  exit 1
fi

# ------------------------------------------------------------------- generate
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required (brew install xcodegen)" >&2
  exit 1
fi
# XcodeGen substitutes ${VAR} from the environment, which is how each target gets
# its own PROVISIONING_PROFILE_SPECIFIER. These must be exported before generate:
# a command-line build setting would apply to both targets, and the app and the
# widget sign with different profiles.
export PROGRAMA_IOS_APP_PROFILE_NAME="$APP_PROFILE_NAME"
export PROGRAMA_IOS_WIDGET_PROFILE_NAME="$WIDGET_PROFILE_NAME"
(cd "$IOS_DIR" && xcodegen generate)

# Fail in seconds rather than after a ~10 minute archive and a consumed upload
# slot. An iPad-capable bundle (TARGETED_DEVICE_FAMILY "1,2") with no declared
# orientations passes the build with only a warning and then HARD FAILS App Store
# validation: "Invalid bundle. No orientations were specified". That cost two
# round trips on the first manual upload, including one that had already created
# the App Store Connect record.
SOURCE_PLIST="$IOS_DIR/ProgramaSpike/Info.plist"
DEVICE_FAMILY="$(grep -m1 'TARGETED_DEVICE_FAMILY' "$IOS_DIR/project.yml" | sed 's/.*"\(.*\)".*/\1/')"
if [[ "$DEVICE_FAMILY" == *"2"* ]]; then
  for key in UISupportedInterfaceOrientations "UISupportedInterfaceOrientations~ipad"; do
    if ! /usr/libexec/PlistBuddy -c "Print :$key" "$SOURCE_PLIST" >/dev/null 2>&1; then
      echo "FAIL: $SOURCE_PLIST declares no :$key, but TARGETED_DEVICE_FAMILY is" >&2
      echo "'$DEVICE_FAMILY' (iPad-capable). App Store validation rejects that bundle." >&2
      echo "Declare it in project.yml under the app target's info.properties, or drop" >&2
      echo "TARGETED_DEVICE_FAMILY to \"1\" if the app should be iPhone-only." >&2
      exit 1
    fi
  done
  echo "Orientations declared for both iPhone and iPad."
fi

# -------------------------------------------------------------------- archive
xcodebuild \
  -project "$IOS_DIR/ProgramaSpike.xcodeproj" \
  -scheme ProgramaSpike \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -clonedSourcePackagesDirPath "$WORK_DIR/source-packages" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DEVELOPMENT_TEAM="$PROGRAMA_IOS_TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  archive

# --------------------------------------------------------------------- export
cat > "$WORK_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>$PROGRAMA_IOS_TEAM_ID</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>$SIGN_IDENTITY</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$APP_BUNDLE_ID</key>
		<string>$APP_PROFILE_NAME</string>
		<key>$WIDGET_BUNDLE_ID</key>
		<string>$WIDGET_PROFILE_NAME</string>
	</dict>
	<key>destination</key>
	<string>export</string>
	<key>uploadSymbols</key>
	<true/>
	<key>compileBitcode</key>
	<false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$WORK_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR"

IPA_PATH="$(ls "$EXPORT_DIR"/*.ipa 2>/dev/null | head -1)"
if [[ -z "$IPA_PATH" ]]; then
  echo "Export produced no .ipa" >&2
  exit 1
fi
echo "Exported: $IPA_PATH"

# ------------------------------------------------------ verify before upload
# Check the SIGNED entitlements, not the profile. The profile is what was
# requested; the signature is what the device enforces, and they can differ.
VERIFY_DIR="$WORK_DIR/verify"
rm -rf "$VERIFY_DIR"; mkdir -p "$VERIFY_DIR"
(cd "$VERIFY_DIR" && unzip -oq "$IPA_PATH")
SIGNED_APP="$VERIFY_DIR/Payload/ProgramaSpike.app"

SIGNED_ENTS="$(codesign -d --entitlements - --xml "$SIGNED_APP" 2>/dev/null || true)"
check_entitlement() {
  local key="$1" expected="$2"
  local actual
  # `plutil -extract` takes a KEYPATH, where an unescaped dot separates levels.
  # Entitlement names are reverse-DNS, so a bare
  # com.apple.developer.icloud-container-environment is read as com -> apple ->
  # developer -> ... and never resolves, while dotless names like aps-environment
  # and get-task-allow happen to work. That asymmetry made a correctly signed
  # build look like it was missing the entitlement. Escape the dots.
  local escaped="${key//./\\.}"
  # plutil also writes "Could not extract value" to STDOUT rather than stderr, so
  # a bare `|| echo "<absent>"` would report the error text as the value.
  if ! actual="$(printf '%s' "$SIGNED_ENTS" | plutil -extract "$escaped" raw -o - - 2>/dev/null)"; then
    actual="<absent>"
  fi
  case "$actual" in *"Could not extract value"*) actual="<absent>" ;; esac
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: signed entitlement $key is '$actual', expected '$expected'" >&2
    return 1
  fi
  echo "  ok  $key = $actual"
}

echo "Verifying signed entitlements:"
verify_failed=0
check_entitlement "aps-environment" "production" || verify_failed=1
check_entitlement "get-task-allow" "false" || verify_failed=1
check_entitlement "com.apple.developer.icloud-container-environment" "Production" || verify_failed=1
if (( verify_failed )); then
  echo "Refusing to upload a build that would not behave correctly in TestFlight." >&2
  exit 1
fi

echo "IPA_PATH=$IPA_PATH"

# --------------------------------------------------------------------- upload
if [[ "${PROGRAMA_IOS_UPLOAD:-0}" != "1" ]]; then
  echo "PROGRAMA_IOS_UPLOAD is not 1; export only, not uploading."
  exit 0
fi

require PROGRAMA_ASC_KEY_ID
require PROGRAMA_ASC_ISSUER_ID
require PROGRAMA_ASC_KEY_P8

# altool finds the key by convention: ./private_keys/AuthKey_<KEYID>.p8 relative
# to one of a fixed set of search paths.
KEY_DIR="$HOME/private_keys"
mkdir -p "$KEY_DIR"
cp "$PROGRAMA_ASC_KEY_P8" "$KEY_DIR/AuthKey_${PROGRAMA_ASC_KEY_ID}.p8"

xcrun altool --upload-app \
  --type ios \
  --file "$IPA_PATH" \
  --apiKey "$PROGRAMA_ASC_KEY_ID" \
  --apiIssuer "$PROGRAMA_ASC_ISSUER_ID"

echo "Uploaded to App Store Connect. Processing takes a few minutes before it appears in TestFlight."
