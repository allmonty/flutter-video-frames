import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:video_frames/video_frames.dart';
import 'package:video_player/video_player.dart';

import 'filters.dart';

void main() => runApp(const MaterialApp(home: FilterPage()));

/// Pick a video, apply a filter to every frame, export it with the original
/// sound, and play the result.
class FilterPage extends StatefulWidget {
  const FilterPage({super.key});

  @override
  State<FilterPage> createState() => _FilterPageState();
}

class _FilterPageState extends State<FilterPage> {
  String? _input;
  VideoFrame? _preview;
  VideoFrame? _filteredPreview;
  Filter _filter = Filter.grayscale;
  double? _progress;
  String _status = 'Pick a video to start.';
  VideoPlayerController? _player;

  Future<void> _pick() async {
    final file = await FilePicker.pickFile(type: FileType.video);
    if (file == null) return;
    // video_frames takes file paths. Pickers usually give one; when they give
    // a content:// URI instead (Android), copy the bytes to a file first.
    var path = file.path;
    if (path == null) {
      path = '${Directory.systemTemp.path}/picked_${file.name}';
      final sink = File(path).openWrite();
      await sink.addStream(file.readAsByteStream());
      await sink.close();
    }
    final reader = await VideoReader.open(path, maxDimension: 480);
    final preview = await reader.frameAt(Duration.zero);
    await reader.close();
    await _player?.dispose();
    setState(() {
      _input = path;
      _preview = preview;
      _player = null;
      _status = file.name;
    });
    _applyFilter(_filter);
  }

  void _applyFilter(Filter filter) {
    final p = _preview;
    setState(() {
      _filter = filter;
      _filteredPreview = p == null
          ? null
          : VideoFrame(pts: p.pts, width: p.width, height: p.height, rgba: filter.apply(p.rgba));
    });
  }

  Future<void> _export() async {
    final input = _input!;
    final output = '${Directory.systemTemp.path}/filtered.mp4';
    setState(() => _progress = 0);
    // A real app can run this loop in a background isolate; the plugin works
    // there too (see the README).
    final reader = await VideoReader.open(input, maxDimension: 1280, filter: ScaleFilter.area);
    final info = reader.info;
    final writer = await VideoWriter.create(
      output,
      width: info.width,
      height: info.height,
      frameRate: info.frameRate,
      audioSourcePath: info.audioCompatible ? input : null,
    );
    try {
      var done = 0;
      // Ask for the next frame before encoding this one, so decoding overlaps encoding.
      var next = reader.nextFrame();
      for (var frame = await next; frame != null; frame = await next) {
        next = reader.nextFrame();
        await writer.addFrame(_filter.apply(frame.rgba), frame.pts);
        done++;
        if (done % 10 == 0) {
          setState(() => _progress = done / info.estimatedFrameCount.clamp(1, 1 << 30));
        }
      }
      await writer.finish();
    } catch (e) {
      await writer.cancel();
      setState(() => _status = 'Export failed: $e');
      return;
    } finally {
      await reader.close();
      setState(() => _progress = null);
    }
    final player = VideoPlayerController.file(File(output));
    await player.initialize();
    await player.setLooping(true);
    await player.play();
    await _player?.dispose();
    setState(() {
      _player = player;
      _status =
          'Exported ${info.width}x${info.height}'
          '${writer.includesAudio ? ' with sound' : ''}.';
    });
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _progress != null;
    final player = _player;
    return Scaffold(
      appBar: AppBar(title: const Text('video_frames: filter a video')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_status),
          const SizedBox(height: 12),
          if (_preview != null && _filteredPreview != null)
            Row(
              children: [
                Expanded(child: _RgbaView(frame: _preview!)),
                const SizedBox(width: 8),
                Expanded(child: _RgbaView(frame: _filteredPreview!)),
              ],
            ),
          const SizedBox(height: 12),
          SegmentedButton<Filter>(
            segments: [
              for (final f in Filter.values) ButtonSegment(value: f, label: Text(f.label)),
            ],
            selected: {_filter},
            onSelectionChanged: busy ? null : (s) => _applyFilter(s.single),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(onPressed: busy ? null : _pick, child: const Text('Pick video')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: busy || _input == null ? null : _export,
                child: const Text('Export'),
              ),
            ],
          ),
          if (busy) ...[const SizedBox(height: 12), LinearProgressIndicator(value: _progress)],
          if (player != null) ...[
            const SizedBox(height: 12),
            AspectRatio(aspectRatio: player.value.aspectRatio, child: VideoPlayer(player)),
          ],
        ],
      ),
    );
  }
}

/// Shows an RGBA frame.
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
      builder: (context, snapshot) => AspectRatio(
        aspectRatio: frame.width / frame.height,
        child: snapshot.hasData ? RawImage(image: snapshot.data, fit: BoxFit.contain) : null,
      ),
    );
  }
}
