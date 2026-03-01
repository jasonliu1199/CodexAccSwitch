#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_FILE="${ROOT_DIR}/menubar/CodexAccountSwitchMenuBar.swift"
DIST_DIR="${ROOT_DIR}/dist"
APP_NAME="Codex Account Switch.app"
APP_DIR="${DIST_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
PLIST_FILE="${CONTENTS_DIR}/Info.plist"
BIN_PATH="${MACOS_DIR}/CodexAccountSwitchMenuBar"

[[ -f "$SRC_FILE" ]] || {
  echo "Source file not found: $SRC_FILE" >&2
  exit 1
}

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

swiftc \
  "$SRC_FILE" \
  -parse-as-library \
  -O \
  -o "$BIN_PATH" \
  -framework Cocoa \
  -framework CryptoKit

cat >"$PLIST_FILE" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>CodexAccountSwitchMenuBar</string>
  <key>CFBundleIdentifier</key>
  <string>com.jasonliu.codex-account-switch</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Codex Account Switch</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
EOF

echo "Built app:"
echo "$APP_DIR"
