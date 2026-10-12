# #3 Parallel decode and encode

**Problem.** All methods share one Pigeon serial queue (one `setUp` = one task queue), so a `nextFrame`
waits behind an `addFrame`.

**Change.**
- `pigeons/messages.dart`: split `VideoFramesHostApi` into `VideoReaderHostApi`
  (`openReader`, `nextFrame`, `frameAt`, `closeReader`) and `VideoWriterHostApi` (the rest). Regenerate.
- `VideoFramesPlugin.kt` / `.swift`: implement both, `setUp` each (two queues).
- `lib/video_frames.dart`: `VideoFrames.readerApi` and `VideoFrames.writerApi` replace `VideoFrames.api`
  (**breaking**; CHANGELOG). Update the `export` line.
- `test/video_frames_test.dart`: `FakeHostApi` → `FakeReaderApi` + `FakeWriterApi`.
- README: overlap only happens if the caller pipelines, so show it:
  ```dart
  var next = reader.nextFrame();
  for (var f = await next; f != null; f = await next) {
    next = reader.nextFrame();               // decode n+1 while encoding n
    await writer.addFrame(process(f.rgba), f.pts);
  }
  ```
- Plugin maps are already locked; readers and writers each own their EGL context (#1), so no shared GL state.

**Test.** Fake-API unit test that a pending `nextFrame` doesn't block `addFrame`. Integration test: the
pipelined loop produces the same frame count.
