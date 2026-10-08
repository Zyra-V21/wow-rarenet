#!/bin/sh
# Bake community loot from the author's SavedVariables into RareNet/ForeverLoot.lua.
# Usage: tools/bake_loot.sh "<WoW>/WTF/Account/<account>/SavedVariables/RareNet.lua" [out]
set -e
cd "$(dirname "$0")/.."
OUT="${2:-RareNet/ForeverLoot.lua}"
TMP=$(mktemp)
node tools/lua.js tools/bake_loot.lua "$1" "$OUT" > "$TMP"
mv "$TMP" "$OUT"
tail -1 "$OUT"
