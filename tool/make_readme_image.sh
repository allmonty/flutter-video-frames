#!/bin/sh
# Regenerate doc/before_after.png (see tool/readme_image/main.swift).
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/video_frames_readme_image"
src=darwin/video_frames/Sources/video_frames
mkdir -p "$out"
xcrun swiftc -O -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  $src/PixelConversion.swift $src/FrameReader.swift $src/FrameWriter.swift \
  tool/readme_image/main.swift -o "$out/make"
"$out/make" doc/before_after.png
