#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:a:h:h}"
APP_DIR="$PROJECT_DIR/.build/release/TokenBar.app"
ROOT_APP_DIR="$PROJECT_DIR/TokenBar.app"

cd "$PROJECT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/.build/release/TokenBar" "$APP_DIR/Contents/MacOS/TokenBar"
cp "$PROJECT_DIR/Bundle/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

rm -rf "$ROOT_APP_DIR"
cp -R "$APP_DIR" "$ROOT_APP_DIR"
codesign --force --deep --sign - "$ROOT_APP_DIR"

echo "$APP_DIR"
