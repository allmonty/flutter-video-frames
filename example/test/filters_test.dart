import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_frames_example/filters.dart';

void main() {
  final pixels = Uint8List.fromList([255, 0, 0, 255, 255, 255, 255, 128]);

  test('grayscale keeps white white and makes red a dark gray', () {
    expect(Filter.grayscale.apply(pixels), [53, 53, 53, 255, 255, 255, 255, 128]);
  });

  test('invert flips color channels but not alpha', () {
    expect(Filter.invert.apply(pixels), [0, 255, 255, 255, 0, 0, 0, 128]);
  });

  test('filters return a copy', () {
    Filter.invert.apply(pixels);
    expect(pixels[0], 255);
  });
}
