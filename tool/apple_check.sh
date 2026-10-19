#!/bin/sh
# Build and run tool/apple_check/main.swift with the plugin's Flutter-free
# Swift sources (PixelConversion, FrameReader, FrameWriter) on macOS.
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/video_frames_apple_check"
src=darwin/video_frames/Sources/video_frames
mkdir -p "$out"
# The pipe hides swiftc's exit status, so drop the old binary: a failed build
# must not rerun it and report a stale pass.
rm -f "$out/check"
xcrun swiftc -O -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  $src/PixelConversion.swift $src/FrameReader.swift $src/FrameWriter.swift $src/AudioMedia.swift \
  tool/apple_check/main.swift -o "$out/check" 2>&1 | grep -v "warning\|^ *[0-9]* |\|^ *|\|^$" || true
[ -x "$out/check" ] || { echo "FAIL build (see errors above)"; exit 1; }
if "$out/check" > "$out/log" 2>&1; then
  cat "$out/log"
else
  status=$?
  cat "$out/log"
  # On GitHub Actions, also show the last lines as an annotation, which is
  # readable on the run page and through the API without opening the log.
  if [ -n "$GITHUB_ACTIONS" ]; then
    echo "::error title=apple_check failed (exit $status)::$(tail -6 "$out/log" | tr '\n' '|')"
  fi
  exit 1
fi
