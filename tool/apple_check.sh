#!/bin/sh
# Build and run tool/apple_check/main.swift with the plugin's Flutter-free
# Swift sources (PixelConversion, FrameReader, FrameWriter) on macOS.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/video_frames_apple_check"
mkdir -p "$out"
say -o "$out/speech.aiff" "video frames audio check"
afconvert -f m4af -d aac "$out/speech.aiff" "$out/speech.m4a"
xcrun swiftc -O -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  ios/Classes/PixelConversion.swift ios/Classes/FrameReader.swift ios/Classes/FrameWriter.swift \
  tool/apple_check/main.swift -o "$out/check" 2>&1 | grep -v "warning\|^ *[0-9]* |\|^ *|\|^$" || true
"$out/check" "$out/speech.m4a" "$out/speech.aiff"
