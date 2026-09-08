#!/bin/bash
# Builds the smallest possible Notchly.app: arm64-only, Release, fully stripped.
# (A Debug build carries a ~5 MB debug dylib + preview dylib — this drops both.)
# Output: ./dist/Notchly.app (ad-hoc signed so the menubar/notch UI behaves).
set -euo pipefail
cd "$(dirname "$0")"

DD="$(mktemp -d)"
echo "▶ Building lean Release (arm64, stripped)…"
xcodebuild -project Notchly.xcodeproj -scheme Notchly -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DD" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES COPY_PHASE_STRIP=YES \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

APP="$DD/Build/Products/Release/Notchly.app"
mkdir -p dist
rm -rf dist/Notchly.app
cp -R "$APP" dist/Notchly.app
codesign --force --deep --sign - dist/Notchly.app >/dev/null 2>&1 || true
rm -rf "$DD"

echo "✓ Built dist/Notchly.app ($(du -sh dist/Notchly.app | cut -f1))"
