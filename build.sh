#!/bin/zsh
# Compila ClaudeSessionSync.app — nessuna dipendenza oltre alla toolchain Swift di Xcode.
set -e
cd "$(dirname "$0")"

APP="ClaudeSessionSync.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Session Sync</string>
  <key>CFBundleDisplayName</key><string>Claude Session Sync</string>
  <key>CFBundleExecutable</key><string>ClaudeSessionSync</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>enterprise.lavder.claude-session-sync</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Lavder Enterprise</string>
</dict></plist>
PLIST

# App icon. Regenerate from the source .icon bundle if the .icns is missing.
if [ ! -f Icon/AppIcon.icns ]; then
  echo "AppIcon.icns not found — generating from Icon/Claude Sync.icon"
  python3 Icon/make_icon.py
fi
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc -O -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -o "$APP/Contents/MacOS/ClaudeSessionSync" \
  Sources/ClaudeSessionSync.swift Sources/UI.swift

# Firma ad-hoc: senza, macOS uccide l'app al lancio su Apple Silicon.
codesign --force --sign - "$APP" 2>/dev/null

echo "Build ok → $(pwd)/$APP"
