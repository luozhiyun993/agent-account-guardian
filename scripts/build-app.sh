#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build -c release --disable-sandbox
APP_DIR="$PROJECT_DIR/dist/Account Guardian.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/AccountGuardian "$APP_DIR/Contents/MacOS/AccountGuardian"
cp packaging/Info.plist "$APP_DIR/Contents/Info.plist"
swift scripts/make-icon.swift "$PROJECT_DIR/.build/Guardian.iconset"
iconutil -c icns "$PROJECT_DIR/.build/Guardian.iconset" -o "$APP_DIR/Contents/Resources/GuardianSafe.icns"
cp "$PROJECT_DIR/.build/Guardian.iconset/icon_256x256@2x.png" "$APP_DIR/Contents/Resources/GuardianMascot.png"
cp "$PROJECT_DIR/.build/Guardian.iconset/icon_512x512@2x.png" "$PROJECT_DIR/dist/guardian-icon-preview.png"
chmod 755 "$APP_DIR/Contents/MacOS/AccountGuardian"
codesign --force --deep --sign - "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
