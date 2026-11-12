#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
ICON_TMP=$(mktemp -d /tmp/nowlater-icon-build.XXXXXX)
trap 'rm -rf "$ICON_TMP"' EXIT
mkdir -p "$ICON_TMP/AppIcon.iconset"
xcrun swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  Design/encode-icon.swift -o "$ICON_TMP/encode-icon"
"$ICON_TMP/encode-icon" Design/app-icon-original.png "$ICON_TMP/AppIcon.iconset"
iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o Resources/AppIcon.icns
# Replace only the known generated iconset; never include the obsolete grayscale/1024px reps.
rm -rf Design/AppIcon.iconset
cp -R "$ICON_TMP/AppIcon.iconset" Design/AppIcon.iconset
echo "Built RGB app icon (up to 512px)."
