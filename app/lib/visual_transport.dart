import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

/// One in-memory frame. Never persisted to the phone or to the agent.
class ScreenFrame {
  const ScreenFrame(this.jpeg, this.width, this.height);
  final Uint8List jpeg;
  final int width;
  final int height;
}

/// Observed in-memory JPEG stream usage, not Wi-Fi PHY/link capacity.
/// Smooth over a short window without uploading or retaining screen frames.
class LiveStreamRate {
  final List<(DateTime, int)> _received = [];

  void clear() => _received.clear();

  void record(ScreenFrame frame, {DateTime? at}) {
    final now = at ?? DateTime.now();
    _received.add((now, frame.jpeg.length));
    _received.removeWhere((sample) =>
        now.difference(sample.$1) > const Duration(seconds: 4));
  }

  double? get framesPerSecond {
    if (_received.length < 2) return null;
    final elapsed = _received.last.$1.difference(_received.first.$1)
        .inMicroseconds / 1000000;
    if (elapsed <= 0) return null;
    return (_received.length - 1) / elapsed;
  }

  double? get megabitsPerSecond {
    if (_received.length < 2) return null;
    final elapsed = _received.last.$1.difference(_received.first.$1)
        .inMicroseconds / 1000000;
    if (elapsed <= 0) return null;
    // Ignore the first packet; its start time is the sampling origin.
    final bytes = _received.skip(1)
        .fold<int>(0, (total, sample) => total + sample.$2);
    return (bytes * 8 / 1000000) / elapsed;
  }
}

/// Aspect-fit screen previews support pinch zoom and clamped translation.
/// Geometry is computed only on the phone: authenticated remote coordinates
/// remain normalized against the full monitor, never the crop or viewport.
class VisualGeometry {
  const VisualGeometry._();

  static Size fittedSize(Size viewport, int imageWidth, int imageHeight) {
    if (viewport.width <= 0 || viewport.height <= 0 ||
        imageWidth <= 0 || imageHeight <= 0) {
      return Size.zero;
    }
    final scale = (viewport.width / imageWidth)
        .clamp(0.0, viewport.height / imageHeight).toDouble();
    return Size(imageWidth * scale, imageHeight * scale);
  }

  /// Don't let the enlarged image be dragged completely out of view.
  /// Axes that still fit the viewport remain centered, without gray gaps.
  static Offset clampPan(Offset candidate, Size viewport, {
    required int imageWidth,
    required int imageHeight,
    required double zoom,
  }) {
    final fit = fittedSize(viewport, imageWidth, imageHeight);
    if (fit == Size.zero || !zoom.isFinite || zoom < 1) {
      return Offset.zero;
    }
    final x = ((fit.width * zoom - viewport.width) / 2).clamp(0.0, double.infinity);
    final y = ((fit.height * zoom - viewport.height) / 2).clamp(0.0, double.infinity);
    return Offset(candidate.dx.clamp(-x, x).toDouble(),
        candidate.dy.clamp(-y, y).toDouble());
  }

  /// Keep the content beneath the starting finger centroid in place while
  /// the fingers scale and travel. startPan is the existing translation.
  static Offset anchoredPan({
    required Offset startFocal,
    required Offset currentFocal,
    required Size viewport,
    required Offset startPan,
    required double startZoom,
    required double newZoom,
    required int imageWidth,
    required int imageHeight,
  }) {
    if (startZoom < 1 || !startZoom.isFinite || !newZoom.isFinite) {
      return Offset.zero;
    }
    final center = Offset(viewport.width / 2, viewport.height / 2);
    final ratio = newZoom / startZoom;
    final candidate = currentFocal - center -
        (startFocal - center - startPan) * ratio;
    return clampPan(candidate, viewport,
        imageWidth: imageWidth, imageHeight: imageHeight, zoom: newZoom);
  }

  static (int, int)? tap(Offset position, Size viewport, {
    required int imageWidth,
    required int imageHeight,
    double zoom = 1.0,
    Offset pan = Offset.zero,
  }) {
    if (zoom < 1 || zoom > 5 || !zoom.isFinite ||
        !pan.dx.isFinite || !pan.dy.isFinite) {
      return null;
    }
    final fit = fittedSize(viewport, imageWidth, imageHeight);
    if (fit == Size.zero) return null;
    final px = (position.dx - viewport.width / 2 - pan.dx) / zoom +
        fit.width / 2;
    final py = (position.dy - viewport.height / 2 - pan.dy) / zoom +
        fit.height / 2;
    if (px < 0 || py < 0 || px > fit.width || py > fit.height) return null;
    return ((px / fit.width * 10000).round().clamp(0, 10000),
        (py / fit.height * 10000).round().clamp(0, 10000));
  }
}

/// Bounded incremental parser for the agent's authenticated MJPEG transport.
/// Parses Content-Length framing, not JPEG byte markers (which are ambiguous).
class MjpegFrameDecoder {
  final List<int> _pending = [];
  int? _expectedLength;
  int _width = 0;
  int _height = 0;

  List<ScreenFrame> add(List<int> bytes) {
    // Process each network chunk incrementally. A single TLS read can contain
    // several valid frames, so bound the *unparsed* buffer, not the input chunk.
    final frames = <ScreenFrame>[];
    for (var start = 0; start < bytes.length; start += 65536) {
      final end = (start + 65536 < bytes.length)
          ? start + 65536 : bytes.length;
      _pending.addAll(bytes.sublist(start, end));
      _parseAvailable(frames);
      if (_pending.length > (2 << 20) + 1024) {
        throw const FormatException('Video frame exceeds safe buffer size.');
      }
    }
    return frames;
  }

  void _parseAvailable(List<ScreenFrame> frames) {
    while (true) {
      if (_expectedLength == null) {
        final headerEnd = _findHeaderEnd();
        if (headerEnd < 0) {
          if (_pending.length > 512) {
            throw const FormatException('Video header exceeds 512 bytes.');
          }
          break;
        }
        final header = ascii.decode(_pending.sublist(0, headerEnd));
        if (!header.startsWith('--ttframe\r\n')) {
          throw const FormatException('Invalid local video frame header.');
        }
        int readHeader(String key) {
          final match = RegExp('^$key: ([0-9]+)', multiLine: true)
              .firstMatch(header.replaceAll('\r', ''));
          return int.tryParse(match?.group(1) ?? '') ?? -1;
        }
        final length = readHeader('Content-Length');
        _width = readHeader('X-Screen-Width');
        _height = readHeader('X-Screen-Height');
        if (length < 1 || length > (2 << 20) ||
            _width < 1 || _width > 1280 || _height < 1 || _height > 720) {
          throw const FormatException('Invalid local video frame dimensions.');
        }
        _expectedLength = length;
        _pending.removeRange(0, headerEnd + 4);
      }
      final count = _expectedLength!;
      if (_pending.length < count + 2) break;
      if (_pending[count] != 13 || _pending[count + 1] != 10) {
        throw const FormatException('Video frame delimiter missing.');
      }
      frames.add(ScreenFrame(
          Uint8List.fromList(_pending.sublist(0, count)), _width, _height));
      _pending.removeRange(0, count + 2);
      _expectedLength = null;
    }
  }

  int _findHeaderEnd() {
    for (var i = 0; i + 3 < _pending.length; i++) {
      if (_pending[i] == 13 && _pending[i+1] == 10 &&
          _pending[i+2] == 13 && _pending[i+3] == 10) { return i; }
    }
    return -1;
  }
}
