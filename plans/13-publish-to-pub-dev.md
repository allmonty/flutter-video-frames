# #13 Publish to pub.dev

**Problem.** The package works but isn't ready for outside users: the pubspec allows Flutter versions it
can't build on, generated channel types are public API, errors aren't typed, and the example doesn't show
the real use case. Do this last, after #1–#12 (especially #3, which is breaking).

**Versioning.**
- Ship #3's breaking split before the first publish, so 1.0.0 is the stable API. Publish as **1.0.0**
  instead of the 1.1.0 in `plans/README.md`; nothing on pub.dev depends on it yet.
- Publishing is permanent (versions can be retracted, not deleted): run every check below first.

**Pubspec (`pubspec.yaml`).**
- Remove `publish_to: none`.
- `flutter: '>=3.3.0'` is wrong: the Android build uses the Flutter 3.47 template (AGP 9) and Dart
  `^3.11.1`. Set it to the oldest Flutter actually built and tested (`>=3.47.0` unless an older one is verified).
- Fill `homepage:` or `repository:` (GitHub URL), add `issue_tracker:`, and add
  `topics: [video, video-processing, encoding, decoding, ffmpeg-alternative]` (max 5).
- Delete the template comment block under `flutter:`.
- Description: mention HEVC if #7 lands ("H.264 or HEVC"), and keep it 60–180 characters.

**Public API surface (`lib/video_frames.dart`).**
- Line 13 exports `VideoFrameMessage`, `VideoFramesHostApi`, `VideoInfoMessage` only for the test seam.
  Once published, any Pigeon regeneration would break users. Move the export to a new
  `lib/testing.dart` (`export 'src/messages.g.dart' show …;`) and mark `VideoFrames.readerApi` /
  `writerApi` (after #3) `@visibleForTesting`. Update `test/video_frames_test.dart` to import
  `package:video_frames/testing.dart`.
- Every public member needs a `///` doc comment (pub.dev scores this; `public_member_api_docs` lint
  in `analysis_options.yaml` catches gaps).

**Typed errors.**
- Today failures reach the app as a raw `PlatformException`. Add `class VideoFramesException implements
  Exception { final VideoFramesErrorCode code; final String message; }` with
  `enum VideoFramesErrorCode { fileNotFound, unsupportedFormat, codecUnsupported, encoderStalled,
  readFailed, writeFailed, unknown }`.
- Native side: throw `FlutterError(code, message)` (Android) / `PigeonError(code:…)` (iOS) with those codes,
  replacing free-text errors (`VideoFramesError` on iOS already has cases to map; "video encoder stalled"
  from #10; "not supported" from #7).
- Dart side: one private `_guard<T>(Future<T> f)` that catches `PlatformException` and rethrows
  `VideoFramesException`, used by every host call in `VideoReader` / `VideoWriter`.
- Test: `FakeHostApi` throws a `PlatformException(code: 'encoderStalled')` → Dart sees
  `VideoFramesException` with the matching code. Document the codes in the README.

**Input paths.**
- Android opens input with `MediaExtractor.setDataSource(path)` (`FrameReader.kt:36,122`,
  `FrameWriter.kt:77`), which takes file paths, not `content://` URIs. iOS uses `URL(fileURLWithPath:)`.
  Document "file paths only" in the `VideoReader.open` / `audioSourcePath` docs and the README;
  pickers like `image_picker` / `file_picker` already return copied file paths.
  `// shortcut: content:// URIs unsupported on Android; add a Context + Uri overload if users ask.`

**Example app (`example/lib/main.dart`).**
- Replace the synthetic clip demo with the real use case: pick a video, apply a simple filter
  (grayscale/invert on the RGBA bytes, or #4 option A with a `FragmentShader`), export, show a progress
  bar from `estimatedFrameCount`, then play or share the result. Keep the synthetic round trip in
  `integration_test` where it already is.
- Picker/player deps go in `example/pubspec.yaml` only; the plugin keeps zero dependencies.

**CI (`.github/workflows/ci.yml`).**
- Linux job: `flutter analyze`, `dart format --set-exit-if-changed .`, `flutter test`,
  `./gradlew :video_frames:testDebugUnitTest` (JDK 17).
- macOS job: `tool/apple_check.sh`.
- Flutter version from `.tool-versions` (`subosito/flutter-action` with the same version).
- Add a CI badge to the README.

**README.**
- Top: one GIF or before/after frames of a filtered video, and a pub.dev install line
  (`flutter pub add video_frames`).
- A short "Compared to" section: no FFmpeg (smaller app, no GPL), read *and* write in one package,
  audio passthrough. Keep it factual, no package bashing.
- Remove the "Bitmapper" reference or explain it in one line.
- Error codes table (from typed errors) and the memory table from #8.

**Optional: macOS.** `tool/apple_check.sh` already runs the Swift core on macOS, so a macOS target is
mostly packaging: add `macos:` to the pubspec `platforms`, a `macos/` podspec + `Package.swift` pointing
at the same sources (`FlutterMacOS` instead of `Flutter` in `VideoFramesPlugin.swift` via
`#if os(iOS)`), and run the example on macOS. Skip if it slows the release; can ship in 1.1.0.

**Release steps.**
1. CHANGELOG: rename "Unreleased" to `1.0.0`, add a line for each item above, bump `pubspec.yaml`.
2. `flutter pub publish --dry-run`: zero warnings.
3. `dart pub global activate pana && pana .`: aim for 160/160 (fix any doc, platform or
   dependency-constraint points it flags).
4. Tag `v1.0.0`, `flutter pub publish`.
5. Optional: verified publisher (needs a domain you own) instead of the personal account; a package can
   be moved to one later, so this doesn't block the release.

**Test.** The usual check set from `plans/README.md`, plus the CI workflow green on a PR, plus the new
typed-error unit test.
