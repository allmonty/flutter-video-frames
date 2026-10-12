import 'dart:typed_data';

/// The example's filters: plain functions over a frame's RGBA bytes.
enum Filter {
  grayscale('Grayscale'),
  invert('Invert');

  const Filter(this.label);

  /// Name shown in the picker.
  final String label;

  /// A filtered copy of `rgba` (row-major RGBA, alpha untouched).
  Uint8List apply(Uint8List rgba) {
    final out = Uint8List.fromList(rgba);
    for (var i = 0; i < out.length; i += 4) {
      switch (this) {
        case Filter.grayscale:
          // BT.709 luma weights, out of 256.
          final y = (54 * out[i] + 183 * out[i + 1] + 19 * out[i + 2]) >> 8;
          out[i] = out[i + 1] = out[i + 2] = y;
        case Filter.invert:
          out[i] = 255 - out[i];
          out[i + 1] = 255 - out[i + 1];
          out[i + 2] = 255 - out[i + 2];
      }
    }
    return out;
  }
}
