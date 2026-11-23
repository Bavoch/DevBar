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
architecture="$(lipo -archs dist/DevBar.app/Contents/MacOS/DevBar)"
codesign --verify --deep --strict dist/DevBar.app
stage="$(mktemp -d "$PWD/dist/.release.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
name="DevBar-$version-$architecture.zip"
if [[ "${1:-}" == --notarize ]]; then
  ditto -c -k --keepParent dist/DevBar.app "$stage/submission.zip"
  xcrun notarytool submit "$stage/submission.zip" --keychain-profile "$DEVBAR_NOTARY_PROFILE" --wait
  xcrun stapler staple dist/DevBar.app
  xcrun stapler validate dist/DevBar.app
  spctl --assess --type execute dist/DevBar.app
else
  name="${name%.zip}-unnotarized.zip"
fi
ditto -c -k --keepParent dist/DevBar.app "$stage/$name"
(cd "$stage" && shasum -a 256 "$name" > "$name.sha256")
mv "$stage/$name" "$stage/$name.sha256" "$PWD/dist/"
print "Packaged: $PWD/dist/$name"
