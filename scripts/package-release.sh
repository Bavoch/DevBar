#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${DEVBAR_SIGN_IDENTITY:-}" != 'Developer ID Application:'* ]]; then
  print -u2 '正式分发需要 DEVBAR_SIGN_IDENTITY 指向 Developer ID Application 证书。'; exit 1
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --notarize ) ]]; then
  print -u2 '用法：package-release.sh [--notarize]'; exit 1
fi
if [[ "${1:-}" == --notarize && -z "${DEVBAR_NOTARY_PROFILE:-}" ]]; then
  print -u2 '公证需要已配置的 DEVBAR_NOTARY_PROFILE Keychain profile。'; exit 1
fi
zsh scripts/build.sh
python3 scripts/check-product.py
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/DevBar.app/Contents/Info.plist)"
architecture="$(uname -m)"
codesign --verify --deep --strict dist/DevBar.app
archive="$PWD/dist/DevBar-$version-$architecture.zip"
ditto -c -k --keepParent dist/DevBar.app "$archive"
if [[ "${1:-}" == --notarize ]]; then
  xcrun notarytool submit "$archive" --keychain-profile "$DEVBAR_NOTARY_PROFILE" --wait
  xcrun stapler staple dist/DevBar.app
  xcrun stapler validate dist/DevBar.app
  spctl --assess --type execute dist/DevBar.app
  ditto -c -k --keepParent dist/DevBar.app "$archive"
  shasum -a 256 "$archive" > "$archive.sha256"
  print "Notarized: $archive"
else
  shasum -a 256 "$archive" > "$archive.sha256"
  print "Signed, not notarized: $archive"
fi
