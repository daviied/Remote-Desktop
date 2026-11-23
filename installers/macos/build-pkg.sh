#!/usr/bin/env bash
# Builds RD-Client-<version>.pkg from the RD Moonlight .dmg (moonlight-qt fork CI).
# Usage: installers/macos/build-pkg.sh <Moonlight.dmg> <version> [out-dir]
# Runs on macOS (GitHub Actions macos runner). The package is unsigned unless
# PKG_SIGN_IDENTITY is set ("Developer ID Installer: ...").
set -euo pipefail
DMG="$1"; VERSION="$2"; OUT="${3:-dist}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'hdiutil detach "$WORK/mnt" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

mkdir -p "$WORK/mnt" "$WORK/root/Applications" "$OUT"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$WORK/mnt" -quiet
APP="$(find "$WORK/mnt" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP" ] || { echo "No .app in $DMG"; exit 1; }
ditto "$APP" "$WORK/root/Applications/Moonlight.app"

# Always install to /Applications (do not "relocate" onto another Moonlight.app copy)
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/components.plist"

pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" \
  --identifier io.github.daviied.rd.client --version "$VERSION" \
  --install-location / "$WORK/RD-Client.pkg"

SIGN=()
[ -n "${PKG_SIGN_IDENTITY:-}" ] && SIGN=(--sign "$PKG_SIGN_IDENTITY")
productbuild --identifier io.github.daviied.rd.client --version "$VERSION" \
  --resources "$HERE/resources" --distribution "$HERE/distribution.xml" \
  --package-path "$WORK" ${SIGN[@]+"${SIGN[@]}"} "$OUT/RD-Client-$VERSION.pkg"
echo "Built $OUT/RD-Client-$VERSION.pkg"
