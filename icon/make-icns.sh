#!/bin/bash
# Build AppIcon.icns from a 1024x1024 source PNG using sips + iconutil.
#   ./icon/make-icns.sh [source.png] [out.icns]
set -euo pipefail
SRC="${1:-$(cd "$(dirname "$0")" && pwd)/AppIcon-source.png}"
OUT="${2:-$(cd "$(dirname "$0")" && pwd)/AppIcon.icns}"

TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$TMP"
while read -r sz name; do
  sips -z "$sz" "$sz" "$SRC" --out "$TMP/$name.png" >/dev/null
done <<'SPECS'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
SPECS
iconutil -c icns "$TMP" -o "$OUT"
rm -rf "$(dirname "$TMP")"
echo "wrote $OUT"
