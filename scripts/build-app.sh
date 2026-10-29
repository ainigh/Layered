#!/bin/bash
# Builds App/build/Mindmap.app and App/build/Mindmap.zip (what a release carries). Needs a Mac
# with Xcode or its Command Line Tools; GitHub Actions runs it on every push, so nobody has to
# build anything by hand.
#
#   VERSION=0.1.7 scripts/build-app.sh
#
# UNIVERSAL=0 builds for this Mac's chip only (what `make app` and the in-app updater do).
set -euo pipefail
cd "$(dirname "$0")/../App"

VERSION="${VERSION:-0.0.0-dev}"
COMMIT="${COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
BRANCH="${BRANCH:-main}"
NAME=Mindmap
APP="build/$NAME.app"
BUNDLE_ID=app.layered.mindmap
# CFBundleVersion must be numbers with dots: VERSION's leading numbers (0.1-abc1234 → 0.1), or 0.
if [[ "$VERSION" =~ ^([0-9]+(\.[0-9]+){0,2}) ]]; then BUNDLE_VERSION="${BUNDLE_VERSION:-${BASH_REMATCH[1]}}"; else BUNDLE_VERSION="${BUNDLE_VERSION:-0}"; fi

command -v swift >/dev/null 2>&1 || {
  echo "error: building needs Swift. Install Apple's command line tools (xcode-select --install), then try again." >&2
  exit 3
}

# One build per chip, joined with lipo (whisper.cpp's C flags keep it off SwiftPM's multi-arch build).
if [[ "${UNIVERSAL:-1}" == 1 ]]; then ARCHS=(arm64 x86_64); else ARCHS=(""); fi
BINS=()
for arch in "${ARCHS[@]}"; do
  flags=(-c release)
  if [[ -n "$arch" ]]; then flags+=(--arch "$arch"); fi
  swift build "${flags[@]}"
  BINS+=("$(swift build "${flags[@]}" --show-bin-path)")
done

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ ${#BINS[@]} == 1 ]]; then
  cp "${BINS[0]}/$NAME" "$APP/Contents/MacOS/$NAME"
else
  lipo -create -output "$APP/Contents/MacOS/$NAME" "${BINS[@]/%//$NAME}"
fi
# SwiftPM's resource bundles (the demo maps). Inside Contents/Resources, not beside Contents/:
# codesign refuses anything loose at the bundle's root, and Harness looks here first.
for bundle in "${BINS[0]}"/*.bundle; do
  if [[ -d "$bundle" ]]; then cp -R "$bundle" "$APP/Contents/Resources/"; fi
done

cp Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUNDLE_VERSION" "$APP/Contents/Info.plist"
# What the updater compares with GitHub: the commit this was built from, and the branch it follows.
plutil -replace LayeredCommit -string "$COMMIT" "$APP/Contents/Info.plist"
plutil -replace LayeredBranch -string "$BRANCH" "$APP/Contents/Info.plist"

# Ad-hoc signature: Apple silicon only runs signed code, and this needs no developer account. Its
# designated requirement is the bundle id alone (not this build's hash), so what macOS has allowed
# the app (notifications, files) carries over to the next version instead of being asked again.
codesign --force --sign - --timestamp=none --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "build/$NAME.zip"
echo "built App/$APP ($VERSION, $BRANCH, $COMMIT)"
