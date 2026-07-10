#!/bin/zsh
# Build ClaudeSessionSync.app — no dependency beyond Xcode's Swift toolchain + actool.
set -e
cd "$(dirname "$0")"

APP="ClaudeSessionSync.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- App icon --------------------------------------------------------------
# The icon is authored in Apple Icon Composer (Icon/AppIcon.icon). actool — Apple's own
# asset compiler — renders it into Assets.car (the Liquid Glass icon macOS 26 draws) plus a
# flat AppIcon.icns fallback for older systems. We do NOT hand-convert it.
ICON_OUT="$(mktemp -d)"
xcrun actool "$PWD/Icon/AppIcon.icon" \
  --compile "$ICON_OUT" \
  --platform macosx \
  --minimum-deployment-target 26.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null
cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Session Sync</string>
  <key>CFBundleDisplayName</key><string>Claude Session Sync</string>
  <key>CFBundleExecutable</key><string>ClaudeSessionSync</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>enterprise.lavder.claude-session-sync</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Lavder Enterprise</string>
</dict></plist>
PLIST

# --- Executable ------------------------------------------------------------
swiftc -O -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -o "$APP/Contents/MacOS/ClaudeSessionSync" \
  Sources/ClaudeSessionSync.swift Sources/UI.swift

# Ad-hoc signature: without one, macOS kills the app on launch on Apple Silicon.
codesign --force --sign - "$APP" 2>/dev/null

rm -rf "$ICON_OUT"
echo "Build ok → $(pwd)/$APP"
