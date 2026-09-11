#!/bin/bash
# Builds an Intel-compatible Notchly.app.
#
# Two changes vs. build_release.sh (which ships an Apple-Silicon-only build):
#   1. ARCHS="arm64 x86_64" -> a UNIVERSAL binary that runs natively on Intel
#      Macs AND on Apple Silicon.
#   2. MACOSX_DEPLOYMENT_TARGET=14.0 -> the project normally targets macOS 26.5
#      (Tahoe), which no ordinary Intel Mac can run. Lowering it to macOS 14
#      (Sonoma) lets the app launch on Intel Macs running Sonoma or later.
#      The source uses no macOS-26-only APIs, so this is safe.
#
# Output: ./dist/Notchly-Intel.app (universal, stripped, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

DD="$(mktemp -d)"
echo "▶ Building universal Release (arm64 + x86_64, macOS 14+, stripped)…"
# NOTE: SWIFT_OPTIMIZATION_LEVEL=-Onone works around a Swift 6.3.2 compiler bug:
# the -O performance inliner (EarlyPerfInliner) crashes on x86_64 while compiling
# the synthesized deinit of the generic TrackingHostingView<Content>
# (NotchWindowController.swift). arm64 -O is unaffected, but a universal build must
# also compile x86_64, so we drop optimization. For a menubar/notch UI app this has
# no perceptible runtime cost; it only affects this Intel artifact, not the shipped
# Apple-Silicon build.
xcodebuild -project Notchly.xcodeproj -scheme Notchly -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DD" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET=14.0 \
    SWIFT_OPTIMIZATION_LEVEL="-Onone" \
    ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO \
    DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES COPY_PHASE_STRIP=YES \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

APP="$DD/Build/Products/Release/Notchly.app"
mkdir -p dist
rm -rf dist/Notchly-Intel.app
cp -R "$APP" dist/Notchly-Intel.app
codesign --force --deep --sign - dist/Notchly-Intel.app >/dev/null 2>&1 || true
rm -rf "$DD"

echo "✓ Built dist/Notchly-Intel.app ($(du -sh dist/Notchly-Intel.app | cut -f1))"
echo -n "  architectures: "; lipo -info dist/Notchly-Intel.app/Contents/MacOS/Notchly | sed 's/.*: //'
