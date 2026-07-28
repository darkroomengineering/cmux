#!/usr/bin/env bash
set -euo pipefail

# Reports on an app bundle's embedded Developer ID provisioning profile, if any.
#
# A missing profile is NOT an error today: Programa currently ships with no
# restricted entitlements (no iCloud), so no profile is expected or required.
# This script exists to verify the profile once one is introduced (see
# plans/golden-tumbling-gray.md M3) — it exits non-zero only when a profile
# IS present but is expired or unreadable, since either of those means the
# app would be killed by AMFI at launch despite passing notarization.

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 <app-path>" >&2
  exit 64
fi

app_path="$1"
profile_path="$app_path/Contents/embedded.provisionprofile"

if [[ ! -f "$profile_path" ]]; then
  echo "No embedded.provisionprofile found at $profile_path."
  echo "This is expected for the current build (no restricted entitlements, no profile)."
  exit 0
fi

plist_xml="$(security cms -D -i "$profile_path" 2>/dev/null)" || {
  echo "Embedded provisioning profile is present but could not be decoded (corrupt or unsigned): $profile_path" >&2
  exit 1
}

python3 - "$plist_xml" <<'PYEOF'
import datetime
import plistlib
import sys

xml = sys.argv[1].encode("utf-8")
try:
    profile = plistlib.loads(xml)
except Exception as exc:
    print(f"Embedded provisioning profile is present but unreadable: {exc}", file=sys.stderr)
    sys.exit(1)

name = profile.get("Name", "<unknown>")
expiry = profile.get("ExpirationDate")
entitlements = profile.get("Entitlements", {})

print(f"Profile name: {name}")
print(f"Expiration:   {expiry}")

if isinstance(expiry, datetime.datetime):
    now = datetime.datetime.now(expiry.tzinfo) if expiry.tzinfo else datetime.datetime.utcnow()
    if expiry < now:
        print("Provisioning profile is EXPIRED.", file=sys.stderr)
        sys.exit(1)
else:
    print("Warning: could not read ExpirationDate from profile; skipping expiry check.", file=sys.stderr)

print("Entitlements granted by this profile:")
if entitlements:
    for key, value in entitlements.items():
        print(f"  {key} = {value}")
else:
    print("  (none found)")

print(f"Provisioning profile verified: {name}")
PYEOF
