#!/usr/bin/env bash
# Build cmux iOS (iPhone & iPad) locally with personal Apple Development signing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKSPACE="$ROOT/cmux.xcworkspace"
SCHEME="cmux-ios"
DERIVED_DATA="${CMUX_IOS_DERIVED_DATA:-/tmp/cmux-ios-personal}"
TEAM_ID="${DEVELOPMENT_TEAM:-5RGQ57X2S3}"
IDENTITY="${CODE_SIGN_IDENTITY:-Apple Development: bort.wc.hoffman@gmail.com (5RGQ57X2S3)}"

echo "==> Building cmux iOS (iPhone + iPad) using local personal signing..."
echo "    Workspace:      $WORKSPACE"
echo "    Scheme:         $SCHEME"
echo "    Signing Team:   $TEAM_ID"
echo "    Identity:       $IDENTITY"
echo "    DerivedData:    $DERIVED_DATA"

xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/bmux.app"

if [ ! -d "$APP_PATH" ]; then
  echo "error: built app not found at $APP_PATH" >&2
  exit 1
fi

echo "==> Applying local codesign to $APP_PATH..."
codesign --force --deep --sign "$IDENTITY" "$APP_PATH"

echo "==> Verifying codesign signature..."
codesign -dvvv "$APP_PATH"

echo ""
echo "✓ cmux iOS (iPhone + iPad) build & signing complete:"
echo "  Bundle: $APP_PATH"
echo ""
echo "To deploy to connected iPhone or iPad:"
echo "  xcrun devicectl list devices"
echo "  xcrun devicectl device install app --device <device-id> '$APP_PATH'"
