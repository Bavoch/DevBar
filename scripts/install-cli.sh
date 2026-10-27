#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
destination="${DEVBAR_CLI_DIR:-$HOME/.local/bin}"
if [[ -x "${0:A:h}/../MacOS/DevBar" ]]; then
  entry="${0:A:h}/devbar"
else
  bundle="${DEVBAR_APP_PATH:-/Applications/DevBar.app}"
  if [[ -x "$bundle/Contents/Resources/devbar" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")" == local.devbar.app ]]; then
    entry="$bundle/Contents/Resources/devbar"
  elif [[ -x "$root/dist/DevBar.app/Contents/Resources/devbar" ]]; then
    entry="$root/dist/DevBar.app/Contents/Resources/devbar"
  else
    print -u2 '请先构建或安装 DevBar.app'; exit 1
  fi
fi
mkdir -p "$destination"
if [[ -e "$destination/devbar" || -L "$destination/devbar" ]]; then
  if [[ ! -L "$destination/devbar" ]]; then
    print -u2 "入口已存在，未覆盖：$destination/devbar"; exit 1
  fi
  existing="$(readlink "$destination/devbar")"
  if [[ "$existing" != "$entry" && "$existing" != "$root/scripts/devbar" && "$existing" != "$root/dist/DevBar.app/Contents/Resources/devbar" && "$existing" != /Applications/DevBar.app/Contents/Resources/devbar ]]; then
    print -u2 "入口属于其他工具，未覆盖：$destination/devbar"; exit 1
  fi
fi
if [[ ! -L "$destination/devbar" || "$(readlink "$destination/devbar")" != "$entry" ]]; then
  temporary="$destination/.devbar-link-$$"
  trap 'rm -f "$temporary"' EXIT
  ln -s "$entry" "$temporary"
  mv -f "$temporary" "$destination/devbar"
fi
print "CLI: $destination/devbar"
