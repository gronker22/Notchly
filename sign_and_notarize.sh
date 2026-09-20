#!/bin/bash
# Sign + notarize + staple a built .app so it opens with a normal double-click
# (no "Apple cannot check it for malware", no right-click → Open).
#
# ── ONE-TIME SETUP ────────────────────────────────────────────────────────────
# 1. Join the Apple Developer Program ($99/yr): https://developer.apple.com/programs/
# 2. Create a **Developer ID Application** certificate:
#      Xcode ▸ Settings ▸ Accounts ▸ (your Apple ID) ▸ Manage Certificates
#      ▸ "+" ▸ Developer ID Application
#    (An "Apple Development" cert is NOT enough — it can't notarize.)
# 3. Create an app-specific password at https://appleid.apple.com ▸ Sign-In & Security
#    ▸ App-Specific Passwords, then store notarytool credentials once:
#
#      xcrun notarytool store-credentials notchly-notary \
#        --apple-id "you@example.com" \
#        --team-id  "YOURTEAMID" \
#        --password "abcd-efgh-ijkl-mnop"
#
# ── USAGE ─────────────────────────────────────────────────────────────────────
#   ./build_release.sh && ./sign_and_notarize.sh dist/Notchly.app
#   ./build_intel.sh   && ./sign_and_notarize.sh dist/Notchly-Intel.app
#
# Override the identity/profile with SIGN_IDENTITY / NOTARY_PROFILE env vars.
set -euo pipefail
cd "$(dirname "$0")"

APP="${1:?usage: ./sign_and_notarize.sh <path-to-.app>}"
[ -d "$APP" ] || { echo "✗ No such app bundle: $APP"; exit 1; }
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-notchly-notary}"
ENTITLEMENTS="${ENTITLEMENTS:-Notchly.entitlements}"

# --- preflight: the Developer ID cert is the thing people are missing ---------
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "✗ No 'Developer ID Application' certificate in your keychain."
    echo "  Found instead:"
    security find-identity -v -p codesigning | sed 's/^/     /'
    echo
    echo "  → Join the Apple Developer Program (\$99/yr), then create the cert in"
    echo "    Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application."
    echo "  See the header of this script for the full one-time setup."
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "✗ No notarytool keychain profile named '$PROFILE'."
    echo "  → xcrun notarytool store-credentials $PROFILE \\"
    echo "        --apple-id \"you@example.com\" --team-id \"YOURTEAMID\" --password \"app-specific-password\""
    exit 1
fi

# --- sign (hardened runtime + secure timestamp, both required to notarize) ----
echo "▶ Signing $APP …"
SIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
[ -f "$ENTITLEMENTS" ] && SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# --- notarize -----------------------------------------------------------------
ZIP="${APP%.app}-notarize.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "▶ Submitting to Apple (usually 1–5 minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# --- staple so it works offline / first launch --------------------------------
echo "▶ Stapling the notarization ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"

echo "▶ Gatekeeper assessment:"
spctl --assess --type execute --verbose "$APP" || true
echo "✓ $APP is signed, notarized and stapled — it opens with a normal double-click."
