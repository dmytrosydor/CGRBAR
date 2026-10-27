#!/bin/sh
# Builds build/AppIcon.icns from Assets/logo.svg.
set -eu

cd "$(dirname "$0")/.."

ICONSET="build/AppIcon.iconset"
RENDER="build/render_svg"

mkdir -p build
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swiftc -O Scripts/render_svg.swift -o "$RENDER"

for size in 16 32 128 256 512; do
    "$RENDER" Assets/logo.svg "$ICONSET/icon_${size}x${size}.png" "$size"
    "$RENDER" Assets/logo.svg "$ICONSET/icon_${size}x${size}@2x.png" "$((size * 2))"
done

iconutil -c icns "$ICONSET" -o build/AppIcon.icns
rm -rf "$ICONSET"
echo "Built build/AppIcon.icns"
