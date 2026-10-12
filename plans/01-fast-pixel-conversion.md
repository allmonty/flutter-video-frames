# #1 Fast pixel conversion

**Problem.** Pixels are converted one at a time on the CPU. Android does 3+ `ByteBuffer.get/put` calls per
pixel in `ColorConversion.yuvToRgba/rgbaToYuv` — hundreds of ms per 4K frame.

**Android: move to the GPU.**
- New `android/.../GlRenderer.kt`: EGL display/context setup, one program for `samplerExternalOES`
  (decoder output) and one for `sampler2D` (encoder input), a full-screen quad, `draw(rotation, filter)`,
  `readPixels(ByteBuffer)`. Owned per Decoder / per FrameWriter.
- `FrameReader.Decoder`: configure the codec with a `Surface(SurfaceTexture(texId))` instead of
  `KEY_COLOR_FORMAT = YUV420Flexible`. Do **not** pass `KEY_ROTATION` (we rotate ourselves).
  In `nextAtOrAfter`, `releaseOutputBuffer(index, render = pts >= minPtsUs)` so skipped frames cost
  nothing; for the rendered one wait for `onFrameAvailable` (listener on a `HandlerThread`, with
  the existing `STALL_MS` timeout), `updateTexImage`, draw into an FBO of output size, `glReadPixels`.
  Rotation and the vertical flip go into the texture coordinates together with
  `SurfaceTexture.getTransformMatrix` (it carries the crop rect).
- `FrameWriter`: `KEY_COLOR_FORMAT = COLOR_FormatSurface`, `createInputSurface()`, EGL window surface with
  `EGL_RECORDABLE_ANDROID`. `addFrame`: `glTexSubImage2D` from `ByteBuffer.wrap(rgba)`, draw,
  `eglPresentationTimeANDROID(ptsUs * 1000)`, `eglSwapBuffers`, `drain(false)`.
  `finish`: `codec.signalEndOfInputStream()` instead of queueing an EOS buffer.
- EGL contexts are bound to a thread, and Pigeon's serial queue may hop threads: every public
  call does `eglMakeCurrent` on entry and releases it on exit.
- Delete `ColorConversion.yuvToRgba`, `rgbaToYuv`, `Plane` and their tests; keep `outputSize` and its test.

**iOS: Accelerate (vImage) for the full-size path.**
- `PixelConversion`: when there's no scaling, use `vImageRotate90_ARGB8888` + `vImagePermuteChannels_ARGB8888`
  (BGRA→RGBA) instead of the per-pixel loop. Scaling stays in our code (see #6).
- `rgbaToBgra` in the writer → `vImagePermuteChannels_ARGB8888` with the pixel buffer's `bytesPerRow`.
- Add `Accelerate` to `Package.swift` `linkerSettings` and `video_frames.podspec` `s.frameworks`.

**Tests.**
- Android conversion now only runs on a device: extend `example/integration_test` to check colors of
  the 4 quadrants, scaling, and **rotation** with a small 90°-rotated fixture mp4 checked into
  `example/integration_test/` (made once with `ffmpeg -i in.mp4 -c copy -metadata:s:v rotate=90`).
- Log ms/frame for a 1080p round trip in the integration test, before and after.
- `tool/apple_check.sh` already checks iOS rotation/colors/scaling; it must still pass.

**Risks.** Large rewrite of both Android classes. Emulators render GL in software (works, slower).
Some old devices have external-texture driver bugs; the rotated fixture + color checks catch the common ones.
