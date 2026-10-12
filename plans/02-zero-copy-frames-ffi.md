# #2 Zero-copy frames via FFI (design notes)

**Goal.** Stop copying each frame 2–3 times across the platform channel (33 MB per 4K frame).

**Shape.** Native side owns frame buffers. `nextFrame` returns a pointer address + length; Dart wraps it
with `Pointer<Uint8>.fromAddress(a).asTypedList(len)`. For writing, the writer hands out an input buffer
(`writer.frameBuffer()`), the app fills it, `addFrame(pts)` commits — so Dart needs no allocator and no
`package:ffi`.

**Platforms.** iOS: Swift can return `UnsafeMutableRawPointer` addresses directly. Android: Kotlin can't
expose a direct `ByteBuffer`'s address without JNI → needs a tiny NDK/CMake C file
(`GetDirectBufferAddress`) or `package:jni`. Either adds a native build.

**Lifetime.** A buffer stays valid until the next `nextFrame`/`close` (a ring of 2–3 if #3 pipelines).
Holding a frame after that is use-after-free; offer `frame.copy()` and document it.

**When.** Only after #1, and only if profiling shows the channel copy dominates (~10–20 ms/frame at 4K).
