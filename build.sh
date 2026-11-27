#!/bin/bash
# Builds build/PortSight.app (universal: Apple silicon + Intel) and build/PortSight.zip for GitHub Releases.
#
# Signing and notarisation are optional:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh
#       signs with your certificate and the hardened runtime
#   DEVELOPER_ID=... NOTARY_PROFILE=portsight ./build.sh
#       also notarises and staples. Create the profile once with:
#       xcrun notarytool store-credentials portsight --apple-id you@example.com --team-id TEAMID
# Without DEVELOPER_ID the app is ad-hoc signed, and users open it with right-click > Open the first time.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/PortSight.app
rm -rf "$APP" build/PortSight.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$arch-apple-macos14.0" \
    Sources/*.swift -o "build/PortSight-$arch"
done
lipo -create build/PortSight-arm64 build/PortSight-x86_64 -output "$APP/Contents/MacOS/PortSight"
rm build/PortSight-arm64 build/PortSight-x86_64
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi

(cd build && ditto -c -k --keepParent PortSight.app PortSight.zip)

if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit build/PortSight.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm build/PortSight.zip
  (cd build && ditto -c -k --keepParent PortSight.app PortSight.zip)
fi
echo "Built $APP and build/PortSight.zip"
