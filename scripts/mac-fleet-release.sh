#!/usr/bin/env bash
# bmux Mac Fleet desktop release pipeline (cloudhome Option A, confirmed 2026-08-26).
#
# Runs entirely on real macOS/Apple-silicon hardware (this machine, or a leased
# Mac Fleet node) because Cloudhome's BuildKit is Linux-only and cannot run
# xcodebuild. Cloudhome's amd64 BuildKit job stays orchestration-only.
#
# Stages:
#   1. build   — xcodebuild Release, explicit -derivedDataPath (always runs)
#   2. package — scripts/pack-arcus.sh with BMUX_APP_BUNDLE pinned to stage 1's
#                output (always runs)
#   3. publish — gh release create/upload to rustybret/bmux (opt-in: --publish)
#   4. stamp   — sha256 + commit manifests/bmux/v<version>.json to
#                rustybret/arcus:main (opt-in: --stamp-arcus)
#
# Stages 3 and 4 are irreversible/external (new GitHub Release, a commit pushed
# to another project's main branch) and are OFF by default. Pass the flags
# explicitly after reviewing the printed plan, or set PUBLISH=1 / STAMP_ARCUS=1.
#
# Usage:
#   scripts/mac-fleet-release.sh                          # build + package only (safe, local)
#   scripts/mac-fleet-release.sh --publish                # + GitHub Release on rustybret/bmux
#   scripts/mac-fleet-release.sh --publish --stamp-arcus   # + stamp/commit/push rustybret/arcus
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PUBLISH="${PUBLISH:-0}"
STAMP_ARCUS="${STAMP_ARCUS:-0}"
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --stamp-arcus) STAMP_ARCUS=1 ;;
    *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if [[ "$STAMP_ARCUS" == "1" && "$PUBLISH" != "1" ]]; then
  echo "error: --stamp-arcus requires --publish (the manifest points at a release asset that must exist first)." >&2
  exit 2
fi

VERSION="0.1.0"
if [ -f "$ROOT/package.json" ]; then
  VERSION=$(node -e "
    try { console.log(require('$ROOT/package.json').version || '0.1.0'); }
    catch (e) { console.log('0.1.0'); }
  ")
fi
RELEASE_TAG="v${VERSION}"

# Local personal signing (no full-privilege Developer Program account yet).
#
# cmux.release.entitlements hardcodes application-identifier, team-identifier,
# and keychain-access-groups to upstream manaflow-ai's real Team ID
# (7WLXT3NR37) — a personal cert under a different team (this machine's is
# A6674H4Q2S) can NEVER pass Xcode's automatic-signing provisioning check
# against those entitlements (Apple enforces entitlement team-identifier ==
# signing cert's team). CODE_SIGN_STYLE=Automatic + -allowProvisioningUpdates
# fails with "Failed Registering Bundle Identifier" / "No profiles found" for
# this reason — it is not a scripting bug, it is a real ownership boundary.
#
# Workaround (same pattern proven for the iOS personal build in
# ios/scripts/build-local-personal.sh): build with signing disabled
# (CODE_SIGNING_ALLOWED=NO) so xcodebuild never calls the provisioning API,
# then apply codesign manually afterward. Manual codesign only validates
# entitlements syntax, not team ownership, so it succeeds — but the
# keychain-access-groups entitlement will not actually grant keychain access
# at runtime since we don't own team 7WLXT3NR37. Known limitation until this
# fork has its own Apple Developer Program membership; harmless for local
# Mac Fleet builds that don't rely on cross-app keychain sharing.
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-A6674H4Q2S}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Apple Development: bort.wc.hoffman@gmail.com (5RGQ57X2S3)}"
DERIVED_DATA="/tmp/cmux-release-${VERSION}"
APP_PATH="$DERIVED_DATA/Build/Products/Release/bmux.app"
ASSET_PATH="$ROOT/dist-arcus/bmux-v${VERSION}-darwin-arm64.tar.gz"
MANIFEST_PATH="$ROOT/dist-arcus/arcus-manifest.json"
ARCUS_REPO="rustybret/arcus"
BMUX_REPO="rustybret/bmux"

echo "== bmux Mac Fleet release plan =="
echo "  version:        $VERSION"
echo "  release tag:    $RELEASE_TAG"
echo "  derived data:   $DERIVED_DATA"
echo "  stage 1 build:  xcodebuild Release -> $APP_PATH"
echo "  stage 2 pack:   scripts/pack-arcus.sh -> $ASSET_PATH"
if [[ "$PUBLISH" == "1" ]]; then
  echo "  stage 3 publish: gh release create $RELEASE_TAG on $BMUX_REPO (uploads $ASSET_PATH) [ENABLED]"
else
  echo "  stage 3 publish: SKIPPED (pass --publish to enable)"
fi
if [[ "$STAMP_ARCUS" == "1" ]]; then
  echo "  stage 4 stamp:   commit+push manifests/bmux/${RELEASE_TAG}.json to $ARCUS_REPO:main [ENABLED]"
else
  echo "  stage 4 stamp:   SKIPPED (pass --stamp-arcus to enable, implies --publish)"
fi
echo ""

# --- stage 1: build ---
echo "== stage 1: xcodebuild Release (arm64-only, signing disabled at build time) =="
# Arcus target_matrix only ships darwin-arm64 — building the default universal
# (arm64+x86_64) slice roughly doubles compile time for an architecture this
# release never publishes. Pin to arm64 explicitly.
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: build succeeded but app bundle not found at $APP_PATH" >&2
  exit 1
fi
echo "  built: $APP_PATH"

echo "== stage 1b: rebrand bundle ID + codesign (cmux.personal.entitlements) =="
# Same bundle ID as a possibly-already-running host cmux instance (this very
# shell may be inside one, per the cmux-workspace convention) causes silent
# single-instance self-termination (SIGTERM, no security-log trace) instead of
# a real second launch. Give personal builds their own identifier, mirroring
# reload.sh's per-tag BUNDLE_ID=com.cmuxterm.app.debug.<tag> pattern.
PERSONAL_BUNDLE_ID="${PERSONAL_BUNDLE_ID:-com.cmuxterm.app.personal}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${PERSONAL_BUNDLE_ID}" "$APP_PATH/Contents/Info.plist"
# PlistBuddy leaves resource-fork/xattr detritus codesign refuses to sign over.
xattr -cr "$APP_PATH"
codesign --force --deep --sign "$CODE_SIGN_IDENTITY" \
  --entitlements "$ROOT/cmux.personal.entitlements" "$APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1 | head -20

echo "== stage 1c: launch verification (real launch, not just codesign --verify) =="
# Match by full path, never `pkill -x cmux` — that would also kill any live
# host cmux instance this very session might be running inside of.
pkill -f "$APP_PATH/Contents/MacOS/bmux" 2>/dev/null || true
sleep 0.3
env -u GIT_PAGER -u GH_PAGER open -g "$APP_PATH"
ATTEMPT=0
LAUNCHED=0
while [[ "$ATTEMPT" -lt 20 ]]; do
  if pgrep -f "$APP_PATH/Contents/MacOS/bmux" >/dev/null 2>&1; then
    LAUNCHED=1
    break
  fi
  ATTEMPT=$((ATTEMPT + 1))
  sleep 0.25
done
if [[ "$LAUNCHED" != "1" ]]; then
  echo "error: app did not launch — check 'log show --last 2m --predicate process==\"taskgated-helper\" OR process==\"amfid\"'" >&2
  exit 1
fi
sleep 2
if ! pgrep -f "$APP_PATH/Contents/MacOS/bmux" >/dev/null 2>&1; then
  echo "error: app launched but exited within 2s (crash or single-instance self-termination)" >&2
  exit 1
fi
echo "  launched and running: $APP_PATH"
pkill -f "$APP_PATH/Contents/MacOS/bmux" 2>/dev/null || true

# --- stage 2: package ---
echo "== stage 2: package (scripts/pack-arcus.sh) =="
BMUX_APP_BUNDLE="$APP_PATH" "$ROOT/scripts/pack-arcus.sh"

if [[ ! -f "$ASSET_PATH" ]]; then
  echo "error: expected release archive not found: $ASSET_PATH" >&2
  exit 1
fi

if [[ "$PUBLISH" != "1" ]]; then
  echo ""
  echo "== done (build + package only) =="
  echo "Artifact ready at: $ASSET_PATH"
  echo "Re-run with --publish to create the GitHub Release on $BMUX_REPO."
  exit 0
fi

# --- stage 3: publish ---
echo "== stage 3: publish GitHub Release =="
command -v gh >/dev/null 2>&1 || { echo "error: gh CLI not found" >&2; exit 1; }
gh release view "$RELEASE_TAG" --repo "$BMUX_REPO" >/dev/null 2>&1 && \
  gh release delete "$RELEASE_TAG" --repo "$BMUX_REPO" --yes
gh release create "$RELEASE_TAG" \
  --repo "$BMUX_REPO" \
  --title "bmux ${VERSION}" \
  --notes "Mac Fleet release ($(git rev-parse --short HEAD))" \
  "$ASSET_PATH"
echo "  published: https://github.com/${BMUX_REPO}/releases/tag/${RELEASE_TAG}"

if [[ "$STAMP_ARCUS" != "1" ]]; then
  echo ""
  echo "== done (build + package + publish) =="
  echo "Re-run with --publish --stamp-arcus to stamp+commit the Arcus manifest."
  exit 0
fi

# --- stage 4: stamp arcus manifest ---
echo "== stage 4: stamp Arcus manifest =="
SHA256="$(shasum -a 256 "$ASSET_PATH" | awk '{print $1}')"
ASSET_URL="https://github.com/${BMUX_REPO}/releases/download/${RELEASE_TAG}/$(basename "$ASSET_PATH")"
echo "  sha256: $SHA256"
echo "  url:    $ASSET_URL"

ARCUS_STAGE="/tmp/bmux-arcus-stamp-${VERSION}"
rm -rf "$ARCUS_STAGE"
git clone --depth 1 "https://github.com/${ARCUS_REPO}.git" "$ARCUS_STAGE"
node -e "
  const fs = require('fs');
  const path = '$ARCUS_STAGE/manifests/bmux/${RELEASE_TAG}.json';
  const manifest = JSON.parse(fs.readFileSync('$MANIFEST_PATH', 'utf8'));
  manifest.daemon.target_matrix['darwin-arm64'].asset.sha256 = '$SHA256';
  manifest.daemon.target_matrix['darwin-arm64'].asset.url = '$ASSET_URL';
  fs.mkdirSync(require('path').dirname(path), { recursive: true });
  fs.writeFileSync(path, JSON.stringify(manifest, null, 2) + '\n');
"
cd "$ARCUS_STAGE"
git config user.email "${GIT_AUTHOR_EMAIL:-bmux-release@local}"
git config user.name "${GIT_AUTHOR_NAME:-bmux-mac-fleet-release}"
git add "manifests/bmux/${RELEASE_TAG}.json"
if git diff --cached --quiet; then
  echo "  no manifest changes to commit"
else
  git commit -m "chore(arcus): stamp bmux ${RELEASE_TAG} ($SHA256)"
  git push origin HEAD:main
  echo "  pushed manifests/bmux/${RELEASE_TAG}.json to ${ARCUS_REPO}:main"
fi
rm -rf "$ARCUS_STAGE"

echo ""
echo "== done (full pipeline: build + package + publish + stamp) =="
