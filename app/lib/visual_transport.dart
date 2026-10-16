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

/// Maps points in an aspect-fit, center-zoomed preview to absolute normalized
/// primary-display coordinates, consistent with the macOS Input Core.
class VisualGeometry {
  const VisualGeometry._();

  static (int, int)? tap(Offset position, Size viewport,
      {required int imageWidth, required int imageHeight,
      double zoom = 1.0}) {
    if (viewport.width <= 0 || viewport.height <= 0 ||
        imageWidth <= 0 || imageHeight <= 0 || zoom < 1 ||
        zoom > 5 || !zoom.isFinite) return null;
    final scale = (viewport.width / imageWidth)
        .clamp(0.0, viewport.height / imageHeight);
    if (scale <= 0) return null;
    final w = imageWidth * scale;
    final h = imageHeight * scale;
    // Undo preview zoom around the surface center before letterbox mapping.
    final px = (position.dx - viewport.width / 2) / zoom +
        viewport.width / 2 - (viewport.width - w) / 2;
    final py = (position.dy - viewport.height / 2) / zoom +
        viewport.height / 2 - (viewport.height - h) / 2;
    if (px < 0 || py < 0 || px > w || py > h) return null;
    return ((px / w * 10000).round().clamp(0, 10000),
        (py / h * 10000).round().clamp(0, 10000));
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
    _pending.addAll(bytes);
    if (_pending.length > (2 << 20) + 1024) {
      throw const FormatException('Video frame exceeds safe buffer size.');
    }
    final frames = <ScreenFrame>[];
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
    return frames;
  }

  int _findHeaderEnd() {
    for (var i = 0; i + 3 < _pending.length; i++) {
      if (_pending[i] == 13 && _pending[i+1] == 10 &&
          _pending[i+2] == 13 && _pending[i+3] == 10) return i;
    }
    return -1;
  }
}
