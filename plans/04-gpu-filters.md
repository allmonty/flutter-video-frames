# #4 GPU filters (design notes)

**Option A — app side, no package change (recommended first).** Frame bytes → `ui.decodeImageFromPixels`
→ draw with a Flutter `FragmentShader` → `Picture.toImage` → `toByteData(rawRgba)` → `addFrame`.
Works today. Limits: needs the root isolate (`dart:ui` rendering), so it gives up the background-isolate
loop; two GPU↔CPU transfers per frame. Package deliverable: an example in `example/` + README recipe.

**Option B — native shader stage.** After #1 Android already renders through GL; the reader could take a
fragment shader and apply it before readback. iOS would need Metal or Core Image → two shader languages
and a uniforms API. Large.

**Option C — full GPU transcode** (decode → shader → encode, no Dart bytes). Fastest, but a different package.

**When.** Do A now. Consider B only if A's readback is the measured bottleneck.
