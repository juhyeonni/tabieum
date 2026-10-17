#!/bin/sh
# Tests, builds and signs the app, then writes dist/<name>-<version>.zip and its SHA-256.
# Bump VERSION in Config/product.env first. TABIEUM_SIGN_IDENTITY must name a real certificate, never ad hoc.
set -eu
cd "$(dirname "$0")/.."
. Config/product.env
: "${TABIEUM_SIGN_IDENTITY:?set TABIEUM_SIGN_IDENTITY to the signing certificate name}"

scripts/test.sh
scripts/bundle.sh
app="build/$PRODUCT_NAME.app"
codesign --verify --strict "$app"

zip="dist/$PRODUCT_NAME-$VERSION.zip"
mkdir -p dist
rm -f "$zip" "$zip.sha256"
ditto -c -k --keepParent "$app" "$zip"
(cd dist && shasum -a 256 "$(basename "$zip")" | tee "$(basename "$zip").sha256")
