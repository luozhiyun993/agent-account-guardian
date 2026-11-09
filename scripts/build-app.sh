#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build -c release --disable-sandbox --disable-index-store --triple arm64-apple-macosx
swift build -c release --disable-sandbox --disable-index-store --triple x86_64-apple-macosx
ARM_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/release"
INTEL_DIR="$PROJECT_DIR/.build/x86_64-apple-macosx/release"
APP_DIR="$PROJECT_DIR/dist/Account Guardian.app"
mkdir -p "$PROJECT_DIR/dist"
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/dist/.guardian-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/Account Guardian.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
lipo -create "$ARM_DIR/AccountGuardian" "$INTEL_DIR/AccountGuardian" -output "$STAGED_APP/Contents/MacOS/AccountGuardian"
cp packaging/Info.plist "$STAGED_APP/Contents/Info.plist"
swiftc scripts/make-icon.swift -o "$PROJECT_DIR/.build/guardian-icon-builder"
"$PROJECT_DIR/.build/guardian-icon-builder" "$PROJECT_DIR/.build/Guardian.iconset"
iconutil -c icns "$PROJECT_DIR/.build/Guardian.iconset" -o "$STAGED_APP/Contents/Resources/GuardianSafe.icns"
cp "$PROJECT_DIR/.build/Guardian.iconset/icon_256x256@2x.png" "$STAGED_APP/Contents/Resources/GuardianMascot.png"
cp "$PROJECT_DIR/.build/Guardian.iconset/icon_512x512@2x.png" "$PROJECT_DIR/dist/guardian-icon-preview.png"
chmod 755 "$STAGED_APP/Contents/MacOS/AccountGuardian"
codesign --force --deep --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
if [ -e "$APP_DIR" ]; then
    mv "$APP_DIR" "$STAGING_DIR/previous.app"
fi
if ! mv "$STAGED_APP" "$APP_DIR"; then
    if [ -e "$STAGING_DIR/previous.app" ]; then
        mv "$STAGING_DIR/previous.app" "$APP_DIR"
    fi
    exit 1
fi
printf 'Built: %s\n' "$APP_DIR"
