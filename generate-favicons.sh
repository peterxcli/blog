#!/bin/bash
# 用法: ./generate-favicons.sh <input_image_path>
# 會自動產生 favicon 及多尺寸 icon 到 static/

set -e

if [ $# -ne 1 ]; then
  echo "用法: $0 <input_image_path>"
  exit 1
fi

INPUT_IMAGE="$1"
STATIC_DIR="static"

mkdir -p "$STATIC_DIR"

# 產生 favicon 及多尺寸 icon
magick "$INPUT_IMAGE" -resize 512x512 "$STATIC_DIR/favicon.png"
magick "$INPUT_IMAGE" -resize 32x32 "$STATIC_DIR/favicon-32x32.png"
magick "$INPUT_IMAGE" -resize 16x16 "$STATIC_DIR/favicon-16x16.png"
magick "$INPUT_IMAGE" -resize 192x192 "$STATIC_DIR/android-chrome-192x192.png"
magick "$INPUT_IMAGE" -resize 512x512 "$STATIC_DIR/android-chrome-512x512.png"
magick "$INPUT_IMAGE" -resize 180x180 "$STATIC_DIR/apple-touch-icon.png"
magick "$INPUT_IMAGE" -resize 32x32 "$STATIC_DIR/favicon.ico"

echo "已產生 favicon 及多尺寸 icon 於 $STATIC_DIR/ 下！" 