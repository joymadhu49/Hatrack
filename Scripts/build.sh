#!/usr/bin/env bash
# Build Hatrack.app into build/. With --install, replace /Applications/Hatrack.app and relaunch.
#
#   ./Scripts/build.sh              build only
#   ./Scripts/build.sh --install    build, install to /Applications, launch
#
# Signing: first "Developer ID Application" identity found, else ad hoc.
# Override with HATRACK_SIGNING_IDENTITY="<identity>" or HATRACK_SIGNING_IDENTITY=- for ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Hatrack.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos14" -swift-version 5 Sources/*.swift -o "build/Hatrack-$arch"
done
lipo -create build/Hatrack-arm64 build/Hatrack-x86_64 -output "$APP/Contents/MacOS/Hatrack"

ID="${HATRACK_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"')}"
# HATRACK_SIGNING_IDENTITY=- forces ad hoc signing.
if [[ -n "$ID" && "$ID" != "-" ]]; then
  codesign --force --options runtime --timestamp --sign "$ID" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
[[ "$ID" == "-" ]] && ID=""
echo "Built $APP (signed: ${ID:-ad hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Hatrack || true
  sleep 0.5
  rm -rf /Applications/Hatrack.app
  cp -R "$APP" /Applications/
  open -g /Applications/Hatrack.app
  echo "Installed /Applications/Hatrack.app"
fi
