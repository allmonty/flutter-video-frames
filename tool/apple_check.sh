#!/bin/sh
# Build and run tool/apple_check/main.swift with the plugin's Flutter-free
# Swift sources (PixelConversion, FrameReader, FrameWriter) on macOS.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/video_frames_apple_check"
src=ios/video_frames/Sources/video_frames
mkdir -p "$out"
say -o "$out/speech.aiff" "video frames audio check"
afconvert -f m4af -d aac "$out/speech.aiff" "$out/speech.m4a"
# The pipe hides swiftc's exit status, so drop the old binary: a failed build
# must not rerun it and report a stale pass.
rm -f "$out/check"
xcrun swiftc -O -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  $src/PixelConversion.swift $src/FrameReader.swift $src/FrameWriter.swift \
  tool/apple_check/main.swift -o "$out/check" 2>&1 | grep -v "warning\|^ *[0-9]* |\|^ *|\|^$" || true
[ -x "$out/check" ] || { echo "FAIL build (see errors above)"; exit 1; }
"$out/check" "$out/speech.m4a" "$out/speech.aiff"
