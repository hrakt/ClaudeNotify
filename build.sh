#!/bin/bash
# Builds ClaudeNotify.app — a tiny menu-bar app that toggles whether Claude Code
# plays its completion sound. Re-run this any time you edit main.swift.
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeNotify.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Drawing icon…"
swiftc -O make-icon.swift -o /tmp/claudenotify-make-icon
rm -rf /tmp/ClaudeNotify.iconset
/tmp/claudenotify-make-icon /tmp/ClaudeNotify.iconset >/dev/null
iconutil -c icns /tmp/ClaudeNotify.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Sources/ holds the app; main.swift is only the entry point, and has to stay
# separate because Swift allows top-level statements in a file with that name
# and nowhere else. make-icon.swift is a second program with its own entry
# point, which is why this is an explicit list rather than a *.swift glob.
echo "Compiling…"
swiftc -O Sources/*.swift main.swift -o "$APP/Contents/MacOS/ClaudeNotify"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Claude Notify</string>
    <key>CFBundleDisplayName</key>     <string>Claude Notify</string>
    <key>CFBundleIdentifier</key>      <string>com.local.claudenotify</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>ClaudeNotify</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Ad-hoc codesign so Gatekeeper/launch is happy locally.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $(pwd)/$APP"
