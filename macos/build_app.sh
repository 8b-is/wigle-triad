#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
mkdir -p "$HERE/bin" "$ROOT/dist"
APP="$HERE/WigleMac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$HERE/wigle-macos.swift" "$APP/Contents/Resources/wigle-macos.swift"

cat > "$HERE/bin/wigle-macos" <<'EOF'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")/.." && pwd)"
exec /usr/bin/swift "$HERE/wigle-macos.swift" "$@"
EOF
chmod +x "$HERE/bin/wigle-macos"

cat > "$APP/Contents/MacOS/WigleMac" <<'EOF'
#!/usr/bin/env bash
RES="$(cd "$(dirname "$0")/../Resources" && pwd)"
exec /usr/bin/swift "$RES/wigle-macos.swift" --gui "$@"
EOF
chmod +x "$APP/Contents/MacOS/WigleMac"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>WigleMac</string>
  <key>CFBundleIdentifier</key>
  <string>dev.vaked.wiglemac</string>
  <key>CFBundleName</key>
  <string>WigleMac</string>
  <key>CFBundleDisplayName</key>
  <string>WigleMac v2.0.0 — 8b-is Heals The World</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>2.0.0</string>
  <key>CFBundleVersion</key>
  <string>200</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>WigleMac uses Location Services so macOS CoreWLAN can read unredacted 802.11 BSSIDs for local observation and CSV export. Location fields in CSV exports are left blank.</string>
  <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
  <string>WigleMac uses Location Services so macOS CoreWLAN can read unredacted 802.11 BSSIDs for local observation and CSV export. Location fields in CSV exports are left blank.</string>
</dict>
</plist>
EOF

echo "[wigle-macos] Compiling Apple Silicon (arm64) + Intel (x86_64) Universal Mach-O binary..."
swiftc -O -target arm64-apple-macos13.0 "$HERE/wigle-macos.swift" -o "$ROOT/dist/wigle-macos-arm64"
swiftc -O -target x86_64-apple-macos13.0 "$HERE/wigle-macos.swift" -o "$ROOT/dist/wigle-macos-x86_64"
lipo -create -output "$ROOT/dist/wigle-macos-v2.0.0-universal-darwin" "$ROOT/dist/wigle-macos-arm64" "$ROOT/dist/wigle-macos-x86_64"
mv "$ROOT/dist/wigle-macos-arm64" "$ROOT/dist/wigle-macos-v2.0.0-arm64-apple-silicon"
rm -f "$ROOT/dist/wigle-macos-x86_64"
chmod +x "$ROOT/dist/wigle-macos-v2.0.0-universal-darwin" "$ROOT/dist/wigle-macos-v2.0.0-arm64-apple-silicon"

(cd "$HERE" && ditto -c -k --sequesterRsrc --keepParent "WigleMac.app" "$ROOT/dist/WigleMac-v2.0.0-macos-apple-silicon.zip")

echo "[wigle-macos] Built CLI wrapper (Apple-signed swift-frontend): $HERE/bin/wigle-macos"
echo "[wigle-macos] Built App bundle: $APP"
echo "[wigle-macos] Built Universal Mach-O: $ROOT/dist/wigle-macos-v2.0.0-universal-darwin"
echo "[wigle-macos] Built Apple Silicon Mach-O: $ROOT/dist/wigle-macos-v2.0.0-arm64-apple-silicon"
echo "[wigle-macos] Packaged App Archive: $ROOT/dist/WigleMac-v2.0.0-macos-apple-silicon.zip"
