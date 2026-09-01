#!/usr/bin/env bash
# Pack bmux desktop application into Arcus release archive & manifest template.
#
# App bundle resolution order:
#   1. $BMUX_APP_BUNDLE (explicit override — used by scripts/mac-fleet-release.sh
#      after a reproducible `xcodebuild -derivedDataPath` build)
#   2. Known local dev build output locations (reload.sh / reloadp.sh / DerivedData)
#   3. None found -> archive ships CLI/Resources only (dev/CI smoke packaging;
#      NOT a valid desktop release artifact)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT/dist-arcus"
mkdir -p "$DIST_DIR"

VERSION="0.1.0"
if [ -f "$ROOT/package.json" ]; then
  VERSION=$(node -e "
    try {
      const pkg = require('$ROOT/package.json');
      console.log(pkg.version || '0.1.0');
    } catch (e) {
      console.log('0.1.0');
    }
  ")
fi

ASSET_BASENAME="bmux-v${VERSION}-darwin-arm64.tar.gz"
ASSET_PATH="$DIST_DIR/$ASSET_BASENAME"

echo "==> Packaging bmux desktop artifact v${VERSION}..."

ARCHIVE_STAGE="/tmp/bmux-arcus-stage"
rm -rf "$ARCHIVE_STAGE"
mkdir -p "$ARCHIVE_STAGE"

# Locate built app bundle
APP_BUNDLE=""
if [ -n "${BMUX_APP_BUNDLE:-}" ]; then
  if [ ! -d "$BMUX_APP_BUNDLE" ]; then
    echo "error: BMUX_APP_BUNDLE set but not found: $BMUX_APP_BUNDLE" >&2
    exit 1
  fi
  APP_BUNDLE="$BMUX_APP_BUNDLE"
else
  for candidate in \
    "/tmp/cmux-personal/Build/Products/Debug/bmux DEV.app" \
    "/tmp/cmux-personal/Build/Products/Release/bmux.app" \
    "/tmp/cmux-release/Build/Products/Release/bmux.app" \
    "/tmp/cmux-ios-personal/Build/Products/Debug-iphoneos/bmux.app" \
    "$HOME/Library/Developer/Xcode/DerivedData/cmux-"*/Build/Products/Release/bmux.app \
    "$HOME/Library/Developer/Xcode/DerivedData/cmux-"*/Build/Products/Debug/*.app; do
    if [ -d "$candidate" ]; then
      APP_BUNDLE="$candidate"
      break
    fi
  done
fi

if [ -n "$APP_BUNDLE" ]; then
  echo "Found app bundle: $APP_BUNDLE"
  cp -R "$APP_BUNDLE" "$ARCHIVE_STAGE/"
else
  echo "warning: no compiled .app bundle found (checked BMUX_APP_BUNDLE + known local paths)." >&2
  echo "warning: this archive will NOT contain a working desktop binary — CLI/Resources only." >&2
  echo "warning: run scripts/mac-fleet-release.sh (or set BMUX_APP_BUNDLE) for a real release build." >&2
fi

# Copy CLI and configs
mkdir -p "$ARCHIVE_STAGE/bin" "$ARCHIVE_STAGE/config"
if [ -d "$ROOT/CLI" ]; then
  cp -R "$ROOT/CLI" "$ARCHIVE_STAGE/"
fi
if [ -d "$ROOT/Resources" ]; then
  cp -R "$ROOT/Resources" "$ARCHIVE_STAGE/"
fi

tar -czf "$ASSET_PATH" -C "$ARCHIVE_STAGE" .
rm -rf "$ARCHIVE_STAGE"

echo "==> Created release archive at $ASSET_PATH ($(du -h "$ASSET_PATH" | cut -f1))"

# Generate matching arcus-manifest.json template
cat > "$DIST_DIR/arcus-manifest.json" <<EOF
{
  "\$schema": "https://raw.githubusercontent.com/rustybret/arcus/main/manifests/schema.json",
  "name": "bmux",
  "version": "${VERSION}",
  "description": "bmux desktop terminal and multi-pane agent workflow environment",
  "daemon": {
    "name": "bmux",
    "service_id": "bmux",
    "protocol_version": 1,
    "target_matrix": {
      "darwin-arm64": {
        "target_triple": "aarch64-apple-darwin",
        "binary_name": "bmux",
        "asset": {
          "filename": "${ASSET_BASENAME}",
          "url": "https://github.com/rustybret/bmux/releases/download/v${VERSION}/${ASSET_BASENAME}",
          "sha256": "PENDING_STAMP_HASH"
        }
      }
    }
  }
}
EOF

echo "==> Emitted $DIST_DIR/arcus-manifest.json"
