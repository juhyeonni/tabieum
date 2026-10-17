#!/bin/sh
# Builds build/<PRODUCT_NAME>.app from the SwiftPM release build, named by Config/product.env.
# TABIEUM_ARCHS="arm64 x86_64" builds each slice and joins them into one universal binary (scripts/release.sh does this).
# Without it the app is built for this Mac only, which is faster.
set -eu
cd "$(dirname "$0")/.."
. Config/product.env

app="build/$PRODUCT_NAME.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
if [ -n "${TABIEUM_ARCHS:-}" ]; then
  slices=""
  for arch in $TABIEUM_ARCHS; do
    swift build -c release --product App --triple "$arch-apple-macosx15.0"
    slices="$slices .build/$arch-apple-macosx/release/App"
  done
  lipo -create -output "$app/Contents/MacOS/$PRODUCT_NAME" $slices
else
  swift build -c release --product App
  bin_dir=$(swift build -c release --show-bin-path)
  cp "$bin_dir/App" "$app/Contents/MacOS/$PRODUCT_NAME"
fi
sed -e "s/__PRODUCT_NAME__/$PRODUCT_NAME/g" \
    -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    -e "s/__URL_SCHEME__/$URL_SCHEME/g" \
    -e "s/__VERSION__/$VERSION/g" \
    -e "s|__REPO__|$REPO|g" \
    Config/Info.plist.in > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" > /dev/null
# A stable identity keeps Keychain "Always Allow" valid across rebuilds; the ad-hoc default changes with every build.
codesign --force --sign "${TABIEUM_SIGN_IDENTITY:--}" "$app"
echo "$app"
