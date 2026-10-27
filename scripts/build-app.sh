#!/usr/bin/env bash
# Build ChatGauge.app with Swift Package Manager only (Xcode not required).
#
#   ./scripts/build-app.sh                  # universal (arm64 + x86_64) when possible
#   ARCHS=arm64 ./scripts/build-app.sh      # Apple silicon only
#   VERSION=1.2.3 ./scripts/build-app.sh    # override version (defaults to ./VERSION)
#   REQUIRE_UNIVERSAL=1 ...                 # fail instead of falling back to fewer archs (CI)
#   CODESIGN_IDENTITY="Developer ID Application: …"  # default "-" (ad-hoc)
#   SWIFT_BUILD_SYSTEM=native               # force a build system (Command Line Tools only: native by default)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="ChatGauge"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS="${ARCHS:-arm64 x86_64}"
MIN_MACOS="14.0"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
IDENTITY="${CODESIGN_IDENTITY:--}"
SWIFT=(xcrun swift)
if [[ -z "${SWIFT_BUILD_SYSTEM:-}" && "$(xcode-select -p 2>/dev/null)" == "/Library/Developer/CommandLineTools" ]]; then SWIFT_BUILD_SYSTEM=native; fi
build_args=()
if [[ -n "${SWIFT_BUILD_SYSTEM:-}" ]]; then build_args+=(--build-system "$SWIFT_BUILD_SYSTEM"); fi

echo "==> $APP_NAME $VERSION ($BUILD_NUMBER) for: $ARCHS"
rm -rf "$DIST"
mkdir -p "$DIST"

binaries=()
for arch in $ARCHS; do
  triple="${arch}-apple-macosx${MIN_MACOS}"
  echo "==> swift build ($triple)"
  if "${SWIFT[@]}" build -c release ${build_args[@]+"${build_args[@]}"} --product "$APP_NAME" --triple "$triple"; then
    bin_dir="$("${SWIFT[@]}" build -c release ${build_args[@]+"${build_args[@]}"} --triple "$triple" --show-bin-path)"
    cp "$bin_dir/$APP_NAME" "$DIST/.$APP_NAME-$arch"
    binaries+=("$DIST/.$APP_NAME-$arch")
  elif [[ "${REQUIRE_UNIVERSAL:-0}" == "1" ]]; then
    echo "error: build for $arch failed" >&2
    exit 1
  else
    echo "warning: build for $arch failed; continuing without it" >&2
  fi
done
[[ ${#binaries[@]} -gt 0 ]] || { echo "error: nothing built" >&2; exit 1; }

echo "==> Assembling $APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
rm -f "${binaries[@]}"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
  Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> App icon"
ICONSET="$DIST/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
cp Resources/retrocombs-logo.png "$APP/Contents/Resources/retrocombs-logo.png"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Codesigning (identity: $IDENTITY)"
sign_args=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then sign_args+=(--options runtime --timestamp); fi
codesign "${sign_args[@]}" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "==> Zipping"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

echo "==> Done"
lipo -archs "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/    archs: /'
echo "    app:   $APP"
echo "    zip:   $ZIP"
echo "    sha256: $(cut -d' ' -f1 < "$ZIP.sha256")"
