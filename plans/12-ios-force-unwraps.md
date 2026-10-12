# #12 iOS force-unwraps

**Problem.** iOS force-unwraps crash the whole app instead of returning an error to Dart.
(Android `!!` throws exceptions that Pigeon already turns into Dart errors, so Android is fine.)

**Change.**
- `FrameReader.convert`: `guard let base = CVPixelBufferGetBaseAddress(pixels)` → throw
  `VideoFramesError.readFailed`; `convert` becomes `throws`.
- `FrameWriter.addFrame`: check the `CVPixelBufferPoolCreatePixelBuffer` return code, guard the pixel
  buffer's base address and `src.baseAddress`, throwing `writeFailed`.
- Leave `as! CMFormatDescription` (CF casts can't fail); add a one-line comment saying so.

**Test.** `tool/apple_check.sh` still passes; these paths only fail under memory pressure.
