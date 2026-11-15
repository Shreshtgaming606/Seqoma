#!/bin/bash
set -euo pipefail

brand_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$brand_dir/.." && pwd)"
build_dir="${SEQOMA_ICON_WORK:-${TMPDIR:-/tmp}/SeqomaIconBuild}"
iconset="$build_dir/Seqoma.iconset"
assets="$brand_dir/IconAssets.xcassets/AppIcon.appiconset"
mkdir -p "$iconset" "$assets"

swift "$brand_dir/make_transparent_icon.swift" \
  "$brand_dir/Seqoma-logo.png" "$brand_dir/Seqoma-logo-transparent.png"

resize_icon() {
  local pixels="$1" asset_name="$2" iconset_name="$3"
  sips -z "$pixels" "$pixels" "$brand_dir/Seqoma-logo-transparent.png" \
    --out "$assets/$asset_name" >/dev/null
  cp "$assets/$asset_name" "$iconset/$iconset_name"
}

resize_icon 16 icon-16.png icon_16x16.png
resize_icon 32 icon-16@2x.png icon_16x16@2x.png
resize_icon 32 icon-32.png icon_32x32.png
resize_icon 64 icon-32@2x.png icon_32x32@2x.png
resize_icon 128 icon-128.png icon_128x128.png
resize_icon 256 icon-128@2x.png icon_128x128@2x.png
resize_icon 256 icon-256.png icon_256x256.png
resize_icon 512 icon-256@2x.png icon_256x256@2x.png
resize_icon 512 icon-512.png icon_512x512.png
resize_icon 1024 icon-512@2x.png icon_512x512@2x.png

iconutil -c icns "$iconset" -o "$project_dir/App/Resources/AppIcon.icns"
echo "Created transparent Seqoma icon assets"
