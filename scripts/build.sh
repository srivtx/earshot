#!/bin/zsh
# Builds dist/Earshot.app (ad-hoc signed). Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "${0:A:h}/.."

APP=dist/Earshot.app
ICON=Resources/AppIcon.icns

if [[ ! -f $ICON ]]; then
  work=$(mktemp -d)
  swift scripts/make-icon.swift "$work/icon.png"
  mkdir -p "$work/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$work/icon.png" --out "$work/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$work/icon.png" --out "$work/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$work/AppIcon.iconset" -o $ICON
  rm -rf "$work"
fi

swift build -c release --arch arm64

rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources/Fonts
cp .build/arm64-apple-macosx/release/Earshot $APP/Contents/MacOS/Earshot
cp Resources/Info.plist $APP/Contents/Info.plist
cp Resources/Fonts/*.ttf $APP/Contents/Resources/Fonts/
cp $ICON $APP/Contents/Resources/AppIcon.icns
codesign --force --sign - --timestamp=none $APP
echo "built $APP"

if [[ ${1:-} == --install ]]; then
  pkill -x Earshot 2>/dev/null || true
  rm -rf /Applications/Earshot.app
  cp -R $APP /Applications/Earshot.app
  open /Applications/Earshot.app
  echo "installed and launched /Applications/Earshot.app"
fi
