#!/bin/bash
# Builds build/PortSight.app (universal: Apple silicon + Intel) and a zip for GitHub Releases.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/PortSight.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$arch-apple-macos14.0" \
    Sources/*.swift -o "build/PortSight-$arch"
done
lipo -create build/PortSight-arm64 build/PortSight-x86_64 -output "$APP/Contents/MacOS/PortSight"
rm build/PortSight-arm64 build/PortSight-x86_64
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS will run it. Replace "-" with a Developer ID to notarise.
codesign --force --sign - "$APP"

(cd build && ditto -c -k --keepParent PortSight.app PortSight.zip)
echo "Built $APP and build/PortSight.zip"
