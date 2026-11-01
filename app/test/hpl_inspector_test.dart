import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/hpl_inspector.dart';
import 'package:taptether/hpl_screen.dart';

void main() {
  test('M4B and MP4 container headers are recognized without DRM claims', () {
    final bytes = Uint8List.fromList([
      0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x4d, 0x34, 0x42, 0x20,
    ]);
    expect(inspectHplBytes('book.m4b', bytes).format,
        'MPEG-4 audio container');
    expect(inspectHplBytes('clip.mp4', bytes).isMedia, isTrue);
    expect(inspectHplBytes('book.m4b', bytes).readiness,
        contains('checking its streams'));
  });

  test('non-media and unknown formats never promise conversion', () {
    final pdf = Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 0x2d]);
    expect(inspectHplBytes('book.pdf', pdf).isMedia, isFalse);
    final unknown = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
    expect(inspectHplBytes('hoopla.data', unknown).format, contains('Unknown'));
    expect(inspectHplBytes('hoopla.data', unknown).readiness,
        contains('Cannot establish'));
  });

  test('MP3 signature enables a conditional, not guaranteed, assessment', () {
    final audio = Uint8List.fromList([0x49, 0x44, 0x33, 3, 0, 0]);
    final result = inspectHplBytes('audio.mp3', audio);
    expect(result.isMedia, isTrue);
    expect(result.readiness, contains('if unprotected'));
  });

  testWidgets('HPL explains sandbox restriction and offers Files picker',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HplScreen()));
    expect(find.text('HPL · Temporary'), findsOneWidget);
    expect(find.textContaining('private app storage'), findsOneWidget);
    expect(find.byKey(const ValueKey('hpl-choose-file')), findsOneWidget);
  });
}
