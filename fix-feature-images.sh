#!/bin/bash
# Finds all feature images under content/ and pads them to 3:2 aspect ratio
# (matching Blowfish card thumbnail ratio of 300x200) with transparent
# background, preserving the original content centered.
#
# - If too narrow: pads width
# - If too tall: pads height

set -e

CONTENT_DIR="$(cd "$(dirname "$0")" && pwd)/content"

if ! command -v magick &> /dev/null; then
  echo "Error: ImageMagick is required. Install with: brew install imagemagick"
  exit 1
fi

# Target aspect ratio: 3:2 (1.5:1), matching Blowfish .thumbnail_card 300x200
TARGET_RATIO_NUM=3
TARGET_RATIO_DEN=2

find "$CONTENT_DIR" -name "feature.*" -type f | while read -r file; do
  dims=$(identify -format "%wx%h" "$file" 2>/dev/null) || continue
  w=$(echo "$dims" | cut -dx -f1)
  h=$(echo "$dims" | cut -dx -f2)

  target_w=$((h * TARGET_RATIO_NUM / TARGET_RATIO_DEN))
  target_h=$((w * TARGET_RATIO_DEN / TARGET_RATIO_NUM))

  if [ "$w" -lt "$target_w" ]; then
    # Too narrow, pad width
    echo "Padding width: $file ($dims -> ${target_w}x${h})"
    magick "$file" -gravity center -background none -extent "${target_w}x${h}" "$file"
  elif [ "$h" -lt "$target_h" ]; then
    # Too wide, pad height
    echo "Padding height: $file ($dims -> ${w}x${target_h})"
    magick "$file" -gravity center -background none -extent "${w}x${target_h}" "$file"
  else
    echo "OK: $file ($dims)"
  fi
done

echo "Done."
