#!/usr/bin/env zsh
# Build a HavenUI.app bundle from the SwiftPM executable + compile Assets.xcassets into Assets.car.
# This avoids needing a manual Xcode project. Tested on Xcode 15+/macOS 14+.
# Usage: scripts/build_app_bundle.sh [Debug|Release]
set -euo pipefail

CONFIG=${1:-Debug}
# Normalize configuration to lowercase for swift build (-c expects 'debug' or 'release')
LOWER_CONFIG=$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')
case "$LOWER_CONFIG" in
  debug|release) : ;; 
  *) echo "Unknown configuration '$CONFIG' (expected Debug or Release)" >&2; exit 2 ;;
esac
ROOT_DIR="${0:A:h:h}"
HUI_DIR="$ROOT_DIR/HavenUI"
ASSETS_DIR="$HUI_DIR/Sources/HavenUI/Resources/Assets.xcassets"
BUILD_DIR="$HUI_DIR/.build"
PRODUCTS_DIR=$(swift build --package-path "$HUI_DIR" -c "$LOWER_CONFIG" --show-bin-path)
BINARY="$PRODUCTS_DIR/HavenUI"
OUT_DIR="$ROOT_DIR/build-bundle"
APP_NAME="HavenUI"
APP_DIR="$OUT_DIR/${APP_NAME}.app"
RES_DIR="$APP_DIR/Contents/Resources"
MACOS_DIR="$APP_DIR/Contents/MacOS"
TMP_ASSET_OUT="$OUT_DIR/asset-compile"
PARTIAL_PLIST="$OUT_DIR/asset-partial.plist"
MIN_DEPLOY="14.0"

mkdir -p "$OUT_DIR"

echo "[1/5] Building SwiftPM executable ($CONFIG)..."
swift build --package-path "$HUI_DIR" -c "$LOWER_CONFIG"

if [[ ! -x "$BINARY" ]]; then
  echo "Failed to find built binary at $BINARY" >&2
  exit 1
fi

echo "[2/5] Compiling asset catalog -> Assets.car"
if [[ ! -d "$ASSETS_DIR" ]]; then
  echo "Asset catalog not found: $ASSETS_DIR" >&2
  exit 1
fi
rm -rf "$TMP_ASSET_OUT" && mkdir -p "$TMP_ASSET_OUT"
ACTOOL=$(xcrun -f actool)
"$ACTOOL" \
  --compile "$TMP_ASSET_OUT" \
  --platform macosx \
  --minimum-deployment-target $MIN_DEPLOY \
  --app-icon AppIcon \
  --enable-on-demand-resources NO \
  --output-partial-info-plist "$PARTIAL_PLIST" \
  --errors --warnings --notices \
  "$ASSETS_DIR" > "$OUT_DIR/actool.log" 2>&1 || {
    echo "actool failed; see $OUT_DIR/actool.log" >&2
    exit 1
  }

if [[ ! -f "$TMP_ASSET_OUT/Assets.car" ]]; then
  echo "Assets.car not produced" >&2
  exit 1
fi

echo "[3/5] Creating .app bundle structure"
rm -rf "$APP_DIR"
mkdir -p "$RES_DIR" "$MACOS_DIR"

INFO_PLIST="$APP_DIR/Contents/Info.plist"
cat > "$INFO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>io.haven.${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_DEPLOY}</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

echo "[3.1] Merging asset catalog plist keys (icon metadata)"
if [[ -s "$PARTIAL_PLIST" ]]; then
  # Integrate CFBundleIconName / CFBundleIconFile so Dock can resolve icon.
  # We just copy expected keys instead of full dictionary merge.
  ICON_NAME=$( /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$PARTIAL_PLIST" 2>/dev/null || echo "AppIcon" )
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$INFO_PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string $ICON_NAME" "$INFO_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconName $ICON_NAME" "$INFO_PLIST" || true
  # Some older tooling still looks at CFBundleIconFile (without extension)
  ICON_FILE=$( /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PARTIAL_PLIST" 2>/dev/null || echo "$ICON_NAME" )
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$INFO_PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $ICON_FILE" "$INFO_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $ICON_FILE" || true
else
  # Fallback: set explicit icon name if partial plist missing
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$INFO_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon" "$INFO_PLIST" || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$INFO_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$INFO_PLIST" || true
fi

# Optional legacy .icns generation to satisfy older Dock caching heuristics
MASTER_1024="$ROOT_DIR/.tmp/appicon/icon_1024.png"
if [[ -f "$MASTER_1024" ]]; then
  ICONSET_DIR="$OUT_DIR/HavenTmp.iconset"
  rm -rf "$ICONSET_DIR" && mkdir -p "$ICONSET_DIR"
  for s in 16 32 128 256 512; do
    s2=$((s*2))
    cp "$ROOT_DIR/.tmp/appicon/icon_${s}.png" "$ICONSET_DIR/icon_${s}x${s}.png" 2>/dev/null || true
    cp "$ROOT_DIR/.tmp/appicon/icon_${s}@2x.png" "$ICONSET_DIR/icon_${s}x${s}@2x.png" 2>/dev/null || true
  done
  cp "$MASTER_1024" "$ICONSET_DIR/icon_512x512@2x.png" 2>/dev/null || true
  if command -v iconutil >/dev/null; then
    iconutil -c icns "$ICONSET_DIR" -o "$RES_DIR/AppIcon.icns" 2>/dev/null || true
  fi
fi

echo "[4/5] Copying binary + assets"
cp "$BINARY" "$MACOS_DIR/${APP_NAME}"
strip -x "$MACOS_DIR/${APP_NAME}" 2>/dev/null || true
cp "$TMP_ASSET_OUT/Assets.car" "$RES_DIR/"

# (Optional) embed uncompiled asset sources for debug reference
mkdir -p "$RES_DIR/OriginalAssets"
cp -R "$ASSETS_DIR" "$RES_DIR/OriginalAssets/" 2>/dev/null || true

# Make sure executable bit
chmod +x "$MACOS_DIR/${APP_NAME}"

# Basic codesign ad-hoc (avoids quarantine warnings)
if command -v codesign >/dev/null; then
  echo "[5/5] Ad-hoc codesigning bundle"
  codesign --force -s - "$APP_DIR" || true
fi

echo "\nBundle created: $APP_DIR"
echo "Run: open '$APP_DIR'"
echo "Log (actool): $OUT_DIR/actool.log"
