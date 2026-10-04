#!/bin/sh
# Builds Resources/TodoNotch.icns from the drawn 1024 px icon.
set -eu
cd "$(dirname "$0")/.."
mkdir -p Resources
swift scripts/make-icon.swift Resources/icon-1024.png
set_dir=Resources/TodoNotch.iconset
rm -rf "$set_dir"
mkdir -p "$set_dir"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$set_dir/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d Resources/icon-1024.png --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o Resources/TodoNotch.icns
rm -rf "$set_dir"
echo "wrote Resources/TodoNotch.icns"
