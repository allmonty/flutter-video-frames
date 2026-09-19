import 'dart:io';
import 'dart:typed_data';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:video_frames/video_frames.dart';

void main() => runApp(const MaterialApp(home: DemoPage()));

/// Writes a short synthetic clip, reads it back and shows a decoded frame.
class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  String _status = 'Tap run';
  VideoFrame? _frame;

  Future<void> _run() async {
    setState(() => _status = 'Encoding...');
    final path = '${Directory.systemTemp.path}/video_frames_demo.mp4';
    const w = 256, h = 144;
    final writer = await VideoWriter.create(path, width: w, height: h, frameRate: 30);
    for (var i = 0; i < 60; i++) {
      final rgba = Uint8List(w * h * 4);
      for (var p = 0; p < w * h; p++) {
        final x = p % w;
        rgba[p * 4] = (x + i * 4) % 256;
        rgba[p * 4 + 1] = (p ~/ w) * 255 ~/ h;
        rgba[p * 4 + 2] = 128;
        rgba[p * 4 + 3] = 255;
      }
      await writer.addFrame(rgba, Duration(microseconds: i * 33333));
    }
    await writer.finish();
    setState(() => _status = 'Decoding...');
    final reader = await VideoReader.open(path);
    final frame = await reader.frameAt(const Duration(seconds: 1));
    await reader.close();
    setState(() {
      _frame = frame;
      _status =
          '${reader.info.width}x${reader.info.height}, '
          '${reader.info.duration.inMilliseconds} ms, frame at ${frame.pts.inMilliseconds} ms';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('video_frames')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_status),
            if (_frame != null) _RgbaView(frame: _frame!),
            FilledButton(onPressed: _run, child: const Text('Run')),
          ],
        ),
      ),
    );
  }
}

class _RgbaView extends StatelessWidget {
  const _RgbaView({required this.frame});
  final VideoFrame frame;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: () async {
        final buffer = await ui.ImmutableBuffer.fromUint8List(frame.rgba);
        final descriptor = ui.ImageDescriptor.raw(
          buffer,
          width: frame.width,
          height: frame.height,
          pixelFormat: ui.PixelFormat.rgba8888,
        );
        final codec = await descriptor.instantiateCodec();
        return (await codec.getNextFrame()).image;
      }(),
      builder: (context, snapshot) => snapshot.hasData
          ? RawImage(image: snapshot.data, width: 256)
          : const SizedBox(height: 144),
    );
  }
}
