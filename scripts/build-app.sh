#!/bin/zsh
# Builds Cosmos.app with nothing but SwiftPM and the Command Line Tools (no Xcode needed).
#
#   scripts/build-app.sh            release build -> build/Cosmos.app
#   scripts/build-app.sh --debug    debug build   -> build/Cosmos.app (faster to produce)
#   scripts/build-app.sh --install  also copy the app to ~/Applications
#
# The app is ad-hoc signed, so macOS will ask you to confirm the first launch (right-click > Open).
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=release
INSTALL=0
for arg in "$@"; do
  case $arg in
    --debug) CONFIG=debug ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done

VERSION=$(cat VERSION 2>/dev/null || echo "1.0")
APP=build/Cosmos.app
echo "==> swift build -c $CONFIG"
swift build -c $CONFIG --product Cosmos 2>&1 | grep -v "ld: warning" | tail -3
swift build -c $CONFIG --product cosmos-cli 2>&1 | grep -v "ld: warning" | tail -1
BIN=$(swift build -c $CONFIG --show-bin-path)

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Cosmos" "$APP/Contents/MacOS/Cosmos"
cp "$BIN/cosmos-cli" "$APP/Contents/MacOS/cosmos-cli"
for bundle in "$BIN"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done

echo "==> icon"
ICON_SOURCE="cosmos icon/cosmos-galaxy-icon.png"
[[ -f $ICON_SOURCE ]] || { echo "missing $ICON_SOURCE"; exit 1 }
ICONSET=build/Cosmos.iconset
rm -rf $ICONSET && mkdir -p $ICONSET
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICON_SOURCE" --out $ICONSET/icon_${size}x${size}.png >/dev/null
  sips -z $((size*2)) $((size*2)) "$ICON_SOURCE" --out $ICONSET/icon_${size}x${size}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/Cosmos.icns"
rm -rf $ICONSET

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cosmos</string>
  <key>CFBundleDisplayName</key><string>Cosmos</string>
  <key>CFBundleIdentifier</key><string>app.cosmos.browser</string>
  <key>CFBundleExecutable</key><string>Cosmos</string>
  <key>CFBundleIconFile</key><string>Cosmos</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web address</string>
      <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
      <key>CFBundleTypeRole</key><string>Viewer</string>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>HTML document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>public.html</string><string>public.xhtml</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Web location</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>com.apple.web-internet-location</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.cosmos.sidebar-item</string>
      <key>UTTypeDescription</key><string>Cosmos sidebar item</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
  <key>NSCameraUsageDescription</key><string>Websites you allow can use your camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>Websites you allow can use your microphone.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Websites you allow can use your location.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Cosmos can save or upload files from your Desktop when you ask it to.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Cosmos can save or upload files from your Documents when you ask it to.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Cosmos saves downloads to your Downloads folder.</string>
</dict>
</plist>
PLIST

echo "==> signing (ad hoc)"
codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --deep "$APP" && echo "signature ok"

if [[ $INSTALL == 1 ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Cosmos.app
  cp -R "$APP" ~/Applications/Cosmos.app
  echo "installed to ~/Applications/Cosmos.app"
fi
echo "done: $APP ($(du -sh "$APP" | cut -f1))"
