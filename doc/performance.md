# Performance baseline

Reference timings, so a change can be compared against them. Re-measure on
the same kind of machine before comparing; numbers from other hardware only
show the order of magnitude. When a change moves a number on purpose, update
the row and say so in the commit.

The test limits are kept far above these numbers, so they catch a path that
falls off vImage or the optimizer, not small slowdowns. This file is for the
small ones.

## Apple: pixel work (`tool/apple_check.sh`)

Release build (`-O`), fastest of 3 runs per line, measured on 2026-11-06 at
`1eecf50` on an Apple M4 running macOS 27.2 with Swift 6.4. Ranges cover 3
runs of the script. The check fails above 50 ms.

| Work | Time per frame |
|---|---|
| Enlarge 480x854 to 1080x1920, `nearest` | 2 ms |
| Enlarge 480x854 to 1080x1920, `bilinear` / `bicubic` / `lanczos` (vImage) | 1-3 ms |
| Shrink 1080x1920 to 480x854, `bilinear` | 5 ms |
| Shrink 1080x1920 to 480x854, `bicubic` / `area` | 6 ms |
| Sharpen a 1080x1920 frame | 2 ms |

```sh
tool/apple_check.sh | grep ' ms$'
```

## Apple: whole pipeline (device test "1080p speed", macOS)

App Debug build, the default for `flutter test integration_test` (the plugin
itself is compiled with `-O`). Same machine, date and commit; 3 runs. 1080p
is 1920x1080. Scaling paths read 10 frames each, decode included. The test
fails if a scaling path takes over 250 ms a frame.

| Work | Time per frame |
|---|---|
| Encode 1080p (H.264) | 9-10 ms |
| Decode 1080p | 5 ms |
| Transcode 1080p, one call at a time | 10-11 ms |
| Transcode 1080p, pipelined | 9 ms |
| Decode 1080p and shrink to 480x270, `area` | 6-7 ms |
| Decode 1080p and shrink to 480x270, `bicubic` | 5 ms |
| Decode 480x270 and enlarge to 1920x1080, `nearest` | 6-7 ms |
| Decode 480x270 and enlarge to 1920x1080, `bicubic` + sharpen 0.8 | 9-10 ms |

```sh
cd example && flutter test integration_test -d macos --plain-name "1080p speed"
```

Before 1.3.1, when the plugin was compiled unoptimized in Debug builds, the
four scaling rows took 409, 841, 1319 and 22 ms.

## Android

Not measured yet. Run the same device test on a phone and add its numbers
here, with the device model and Android version:

```sh
cd example && flutter test integration_test -d <android device> --plain-name "1080p speed"
```
