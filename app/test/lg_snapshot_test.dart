import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_snapshot_pad.dart';
import 'package:taptether/lg_webos_client.dart';

void main() {
  test('LG screenshot response URL stays on the paired TV', () {
    const host = '192.168.68.62';
    expect(safeLgSnapshotUri('http://$host:3000/screenshot/123', host),
        isNotNull);
    expect(safeLgSnapshotUri('https://$host:3001/capture.jpg', host),
        isNotNull);
    expect(safeLgSnapshotUri('https://example.com/image.jpg', host), isNull);
    expect(safeLgSnapshotUri('file:///tmp/capture.jpg', host), isNull);
    expect(safeLgSnapshotUri('http://user:password@$host/a', host), isNull);
    expect(safeLgSnapshotUri('http://$host/x#fragment', host), isNull);
    expect(safeLgSnapshotUri('http://$host.evil.test/image', host), isNull);
  });

  test('LG screenshot image headers and complete endings are required', () {
    final jpeg = Uint8List.fromList(
        [255, 216, 255, ...List.filled(12, 17), 255, 217]);
    final truncated = Uint8List.fromList(
        [255, 216, 255, ...List.filled(12, 17)]);
    expect(isCompleteLgSnapshot(jpeg), isTrue);
    expect(isCompleteLgSnapshot(truncated), isFalse);
    final png = Uint8List.fromList([
      137, 80, 78, 71, 13, 10, 26, 10,
      ...List.filled(10, 0),
      73, 69, 78, 68, 174, 66, 96, 130,
    ]);
    expect(isCompleteLgSnapshot(png), isTrue);
    expect(isCompleteLgSnapshot(Uint8List.fromList(
        [1, 2, 3, ...List.filled(30, 0)])), isFalse);
  });

  testWidgets('LG snapshot fallback preserves touchpad and stays one screen',
      (tester) async {
    var calls = 0;
    var clicks = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(
        width: 390, height: 600,
        child: LgSnapshotPad(
          capture: () async {
            calls++;
            throw StateError('Screenshot blocked by this firmware.');
          },
          movePointer: (dx, dy) async {},
          clickPointer: () async { clicks++; },
          onError: (_) {},
        ),
      )),
    ));
    expect(find.text('Snapshot'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    await tester.tap(find.text('Snapshot'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(calls, 1);
    expect(find.textContaining('Screenshot blocked'), findsOneWidget);
    await tester.tap(find.text('Touchpad').first);
    await tester.pump();
    expect(find.text('Swipe to browse · Tap to click'), findsOneWidget);
    await tester.tap(find.text('Swipe to browse · Tap to click'));
    await tester.pump();
    expect(clicks, 1);
  });
}
