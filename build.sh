#!/bin/zsh
# 构建 NowLater.app（无需 Xcode，仅用命令行工具）
set -e
cd "$(dirname "$0")"

SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
APP=build/NowLater.app

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

xcrun swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -O \
  -framework AppKit \
  -framework SwiftUI \
  -o "$APP/Contents/MacOS/NowLater" \
  Sources/*.swift

codesign --force --sign - "$APP"
APP_BYTES=$(python3 -c 'import os,sys
total = 0
for root, _, files in os.walk(sys.argv[1]):
    for f in files:
        total += os.path.getsize(os.path.join(root, f))
print(total)' "$APP")
if (( APP_BYTES >= 3000000 )); then
  echo "App exceeds the 3 MB limit: $APP_BYTES bytes" >&2
  exit 1
fi
echo "size: $APP_BYTES bytes"
echo "built: $APP"
