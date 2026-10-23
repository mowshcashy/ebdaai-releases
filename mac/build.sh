#!/bin/bash
# Builds EBDAAI.app and EBDAAI-macOS-<version>.dmg from a published macOS server release.
#   ./build.sh            → the latest release
#   ./build.sh 1.0.33     → a specific version
#   ./build.sh 1.0.33 --upload   → also attach the DMG and latest-mac.yml to that release
# Output: mac/dist/  (EBDAAI.app, the DMG, and latest-mac.yml — the feed the Mac app's updater reads)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO=mowshcashy/ebdaai-releases
NODE_LINE=latest-v22.x
UPLOAD=0
ARGS=()
for a in "$@"; do [ "$a" = "--upload" ] && UPLOAD=1 || ARGS+=("$a"); done
VERSION="${ARGS[0]:-$(gh release view -R "$REPO" --json tagName -q .tagName | sed 's/^v//')}"
WORK="$HERE/.build"
DIST="$HERE/dist"
APP="$DIST/EBDAAI.app"

echo "▸ EBDAAI $VERSION for macOS (arm64)"
rm -rf "$APP" && mkdir -p "$WORK" "$DIST"

# 1. Server package from the release
SRV="$WORK/EBDAAI-macOS-server-$VERSION"
if [ ! -d "$SRV" ]; then
  gh release download "v$VERSION" -R "$REPO" -p "EBDAAI-macOS-server-$VERSION.tar.gz" -D "$WORK" --clobber
  tar -xzf "$WORK/EBDAAI-macOS-server-$VERSION.tar.gz" -C "$WORK"
fi

# 2. Node.js for Apple Silicon, checked against the official checksums
NODE_TGZ=$(curl -fsSL "https://nodejs.org/dist/$NODE_LINE/SHASUMS256.txt" | awk '/darwin-arm64.tar.gz$/{print $2}')
NODE_DIR="$WORK/${NODE_TGZ%.tar.gz}"
if [ ! -d "$NODE_DIR" ]; then
  curl -fsSL -o "$WORK/$NODE_TGZ" "https://nodejs.org/dist/$NODE_LINE/$NODE_TGZ"
  (cd "$WORK" && curl -fsSL "https://nodejs.org/dist/$NODE_LINE/SHASUMS256.txt" | grep " $NODE_TGZ\$" | shasum -a 256 -c -)
  tar -xzf "$WORK/$NODE_TGZ" -C "$WORK"
fi

# The newest CommandLineTools SDK can be ahead of its own swiftc; prefer the one that matches.
SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | tail -1 || true); SDK=${SDK:-$(xcrun --show-sdk-path)}

# 3. Icon from the logo, with its animation frozen at the finished frame
ICONSET="$WORK/EBDAAI.iconset"
if [ ! -f "$WORK/EBDAAI.icns" ]; then
  python3 -c 'import re,sys; s=open(sys.argv[1]).read(); s=re.sub(r"<style>.*?</style>","",s,flags=re.S); print(s.replace("width=\"240\" height=\"240\"","width=\"1024\" height=\"1024\"").replace("class=\"glow\"","class=\"glow\" opacity=\".85\""))' \
    "$HERE/../assets/logo-motion.svg" > "$WORK/icon.svg"
  swift -sdk "$SDK" "$HERE/svg2png.swift" "$WORK/icon.svg" "$WORK/icon.svg.png" 1024
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$WORK/icon.svg.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$WORK/icon.svg.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$WORK/EBDAAI.icns"
fi

# 4. The app bundle
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/node/bin"
swiftc -O -sdk "$SDK" -target arm64-apple-macos13 -o "$APP/Contents/MacOS/EBDAAI" "$HERE/main.swift" "$HERE/Updater.swift"
cp "$NODE_DIR/bin/node" "$APP/Contents/Resources/node/bin/node"
cp "$NODE_DIR/LICENSE" "$APP/Contents/Resources/node/LICENSE"
cp -R "$SRV/app" "$APP/Contents/Resources/app"
cp "$WORK/EBDAAI.icns" "$APP/Contents/Resources/EBDAAI.icns"
sed "s/__VERSION__/$VERSION/g" "$HERE/Info.plist" > "$APP/Contents/Info.plist"

# Ad-hoc signature: Apple Silicon refuses to run unsigned code. (Not notarized.)
codesign --force --deep --sign - "$APP"

# 5. DMG with an Applications shortcut
DMG="$DIST/EBDAAI-macOS-$VERSION.dmg"
STAGE="$WORK/dmg"
rm -rf "$STAGE" "$DMG" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "EBDAAI $VERSION" -srcfolder "$STAGE" -fs HFS+ -format ULMO -ov "$DMG" >/dev/null

# 6. The update feed: same fields as electron-builder's latest.yml
FEED="$DIST/latest-mac.yml"
{
  echo "version: $VERSION"
  echo "path: $(basename "$DMG")"
  echo "sha512: $(openssl dgst -sha512 -binary "$DMG" | base64)"
  echo "releaseDate: '$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'"
  echo "releaseNotes: |"
  gh release view "v$VERSION" -R "$REPO" --json body -q .body 2>/dev/null \
    | grep -E '^- ' | grep -v 'تطبيق للماك' | head -6 | sed 's/^/  /'
} > "$FEED"

du -sh "$APP" "$DMG"
echo "✓ $DMG"

if [ "$UPLOAD" = 1 ]; then
  gh release upload "v$VERSION" -R "$REPO" --clobber "$DMG" "$FEED"
  echo "✓ uploaded to v$VERSION"
fi
