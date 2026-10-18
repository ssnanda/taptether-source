import 'dart:convert';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/visual_transport.dart';

void main() {
  test('screen preview maps only the actual fitted image area', () {
    expect(VisualGeometry.tap(const Offset(200, 150),
        const Size(400, 300), imageWidth: 1280, imageHeight: 720),
        (5000, 5000));
    expect(VisualGeometry.tap(const Offset(0, 150),
        const Size(400, 300), imageWidth: 1280, imageHeight: 720),
        (0, 5000));
    expect(VisualGeometry.tap(const Offset(200, 10),
        const Size(400, 300), imageWidth: 1280, imageHeight: 720),
        isNull);
    expect(VisualGeometry.tap(const Offset(200, 150),
        const Size(400, 300), imageWidth: 1280, imageHeight: 720,
        zoom: 2), (5000, 5000));
    expect(VisualGeometry.tap(const Offset(0, 0),
        const Size(400, 300), imageWidth: 0, imageHeight: 720),
        isNull);
  });

  test('pinch around finger position keeps same screen content underneath', () {
    const viewport = Size(400, 300);
    final pan = VisualGeometry.anchoredPan(
      startFocal: const Offset(300, 150),
      currentFocal: const Offset(300, 150),
      viewport: viewport, startPan: Offset.zero,
      startZoom: 1, newZoom: 2,
      imageWidth: 1280, imageHeight: 720);
    expect(pan, const Offset(-100, 0));
    expect(VisualGeometry.tap(const Offset(300, 150), viewport,
      imageWidth: 1280, imageHeight: 720, zoom: 2, pan: pan),
      (7500, 5000));
  });

  test('pan clamps to image edges and never loses the screen', () {
    const viewport = Size(400, 300);
    expect(VisualGeometry.clampPan(const Offset(900, -900), viewport,
        imageWidth: 1280, imageHeight: 720, zoom: 2),
        const Offset(200, -75));
    expect(VisualGeometry.clampPan(const Offset(100, 50), viewport,
        imageWidth: 1280, imageHeight: 720, zoom: 1), Offset.zero);
    expect(VisualGeometry.clampPan(const Offset(0, 80), viewport,
        imageWidth: 1280, imageHeight: 720, zoom: 1.2),
        const Offset(0, 0)); // vertical content still letterboxed
  });

  test('panned viewport taps map to actual computer coordinates', () {
    const viewport = Size(400, 300);
    expect(VisualGeometry.tap(const Offset(200, 150), viewport,
      imageWidth: 1280, imageHeight: 720,
      zoom: 2, pan: const Offset(100, -40)), (3750, 5889));
    expect(VisualGeometry.tap(const Offset(-100, 150), viewport,
      imageWidth: 1280, imageHeight: 720, zoom: 2), isNull);
    expect(VisualGeometry.tap(const Offset(200, 150), viewport,
      imageWidth: 1280, imageHeight: 720,
      zoom: 2, pan: const Offset(double.nan, 0)), isNull);
  });

  test('stream frame decoding survives chunk boundaries', () {
    final parser = MjpegFrameDecoder();
    final payload = <int>[
      ...ascii.encode('--ttframe\r\nContent-Type: image/jpeg\r\n'
          'Content-Length: 3\r\nX-Screen-Width: 1280\r\n'
          'X-Screen-Height: 720\r\n\r\n'),
      1, 2, 3, 13, 10,
    ];
    expect(parser.add(payload.sublist(0, 12)), isEmpty);
    final images = parser.add(payload.sublist(12));
    expect(images, hasLength(1));
    expect(images.single.jpeg, [1,2,3]);
    expect(images.single.width, 1280);
    expect(images.single.height, 720);
    expect(parser.add(payload), hasLength(1));
  });

  test('stream accepts multiple frames delivered in one large network chunk', () {
    final parser = MjpegFrameDecoder();
    final jpeg = List<int>.filled(900000, 42);
    final header = ascii.encode('--ttframe\r\nContent-Type: image/jpeg\r\n'
        'Content-Length: 900000\r\nX-Screen-Width: 1280\r\n'
        'X-Screen-Height: 720\r\n\r\n');
    final one = <int>[...header, ...jpeg, 13, 10];
    final frames = parser.add([...one, ...one, ...one]);
    expect(frames, hasLength(3));
    expect(frames.every((frame) => frame.jpeg.length == 900000), isTrue);
  });

  test('stream refuses oversized buffers', () {
    final parser = MjpegFrameDecoder();
    expect(() => parser.add(List.filled((2 << 20) + 1025, 1)),
        throwsFormatException);
  });
}
