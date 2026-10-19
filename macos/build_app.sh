#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/bin"
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
  <string>WigleMac — MEDUSA Triad</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.8.0</string>
  <key>CFBundleVersion</key>
  <string>0.8.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>WigleMac uses Location Services so macOS CoreWLAN can read unredacted 802.11 BSSIDs and attach coordinates to WiGLE v1.4 CSV exports.</string>
  <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
  <string>WigleMac uses Location Services so macOS CoreWLAN can read unredacted 802.11 BSSIDs and attach coordinates to WiGLE v1.4 CSV exports.</string>
</dict>
</plist>
EOF

echo "[wigle-macos] Built CLI wrapper (Apple-signed swift-frontend): $HERE/bin/wigle-macos"
echo "[wigle-macos] Built App bundle: $APP"
