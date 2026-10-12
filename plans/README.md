# Improvement plans

One plan per issue found in the code review. Numbers match the review; the order below is the order to do them in.

Execution order (dependencies in brackets):

1. #9 Android `finish()` leak — small, standalone
2. #10 Android encoder stall — small, standalone
3. #12 iOS force-unwraps — small; do before #1 touches the same lines
4. #11 Unclosed readers/writers — small, Dart + iOS
5. #1 Fast pixel conversion — Android GPU rewrite + iOS vImage [after 9, 10, 12]
6. #5 HD color — mostly falls out of #1 on Android [after 1]
7. #6 Scaling filter choice [after 1: Android filter lives in the shader]
8. #3 Parallel decode/encode — API split [after 1: each GPU object owns its EGL context]
9. #7 HDR input + HEVC output [after 1, 5]
10. #8 Memory at 4K [after 1]
11. #2, #4 — only if profiling after 1–10 shows they're the bottleneck

API changes: #3 is **breaking** (`VideoFrames.api` splits in two). #6, #7 add optional parameters.
Add CHANGELOG entries under an "Unreleased" heading as fixes land; when all fixes are in, bump `pubspec.yaml` to 1.1.0 and rename the heading to 1.1.0.

Every plan ends with the same check set: `flutter analyze`, `flutter test`,
`cd example/android && ./gradlew :video_frames:testDebugUnitTest`, `tool/apple_check.sh`,
`cd example && flutter test integration_test` on an Android emulator **and** an iOS simulator.
