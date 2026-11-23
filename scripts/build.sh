#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
mkdir -p dist
stage="$PWD/dist/.DevBar-build-$$.app"
previous="$PWD/dist/.DevBar-previous-$$.app"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp .build/release/DevBar "$stage/Contents/MacOS/DevBar"
cp -R .build/release/DevBar_DevBar.bundle "$stage/Contents/Resources/"
cp scripts/devbar scripts/install-cli.sh "$stage/Contents/Resources/"
cp -R drivers "$stage/Contents/Resources/drivers"
find "$stage/Contents/Resources/drivers" -type d -name __pycache__ -prune -exec rm -rf {} +
mkdir "$stage/Contents/Resources/docs"
cp docs/{launch-permissions,open-source-readiness,platform-matrix,product-principles,production-review,release,sync-contract}.md docs/sync.schema.json "$stage/Contents/Resources/docs/"
mkdir -p "$stage/Contents/Resources/website/assets"
cp website/assets/devbar-panel.png "$stage/Contents/Resources/website/assets/"
cp README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md LICENSE "$stage/Contents/Resources/"
sips -s format icns icon.png --out "$stage/Contents/Resources/DevBar.icns" >/dev/null
chmod +x "$stage/Contents/Resources/devbar" "$stage/Contents/Resources/install-cli.sh"
cat > "$stage/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DevBar</string>
<key>CFBundleIdentifier</key><string>local.devbar.app</string>
<key>CFBundleName</key><string>DevBar</string>
<key>CFBundleIconFile</key><string>DevBar.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.16.0</string>
<key>CFBundleVersion</key><string>33</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -n "${DEVBAR_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVBAR_SIGN_IDENTITY" "$stage"
else
  codesign --force --sign - "$stage"
fi
codesign --verify --strict "$stage"
if [[ -e dist/DevBar.app ]]; then mv dist/DevBar.app "$previous"; fi
if ! mv "$stage" dist/DevBar.app; then
  if [[ -e "$previous" ]]; then mv "$previous" dist/DevBar.app; fi
  exit 1
fi
rm -rf "$previous"
print "Built: $PWD/dist/DevBar.app"
