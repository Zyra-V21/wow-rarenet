#!/bin/sh
# Build the release zip for CurseForge: RareNet-<version>.zip with the addon
# folder and the license, into the directory given as $1.
set -e
cd "$(dirname "$0")/.."
OUT="${1:-dist}"
VERSION=$(sed -n 's/^## Version: //p' RareNet/RareNet.toc)
STAGE=$(mktemp -d)
cp -r RareNet "$STAGE/RareNet"
cp LICENSE "$STAGE/RareNet/LICENSE.txt"
cp NOTICE "$STAGE/RareNet/NOTICE.txt"
mkdir -p "$OUT"
rm -f "$OUT/RareNet-$VERSION.zip"
(cd "$STAGE" && zip -qr "RareNet-$VERSION.zip" RareNet)
mv "$STAGE/RareNet-$VERSION.zip" "$OUT/"
rm -rf "$STAGE"
echo "$OUT/RareNet-$VERSION.zip"
