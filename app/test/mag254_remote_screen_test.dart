import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/mag254_remote_screen.dart';
import 'package:taptether/mag254_store.dart';

class _MemoryMagStore extends Mag254Store {
  final devices = <Mag254Device>[];

  @override
  Future<List<Mag254Device>> read() async => List.of(devices);

  @override
  Future<void> save(Mag254Device device) async {
    devices.removeWhere((item) => item.deviceId == device.deviceId ||
        item.host == device.host);
    devices.add(device);
  }

  @override
  Future<void> remove(Mag254Device device) async {
    devices.removeWhere((item) => item.deviceId == device.deviceId);
  }
}

void main() {
  testWidgets('MAG254 offline save keeps Connect separate',
      (tester) async {
    final store = _MemoryMagStore();
    await tester.pumpWidget(MaterialApp(
        home: Mag254RemoteScreen(store: store)));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('mag254-host')), '192.168.1.80');
    await tester.enterText(
        find.byKey(const ValueKey('mag254-name')), 'Office MAG');
    await tester.tap(find.byKey(const ValueKey('mag254-save')));
    await tester.pumpAndSettle();
    expect(store.devices.length, 1);
    expect(store.devices.single.paired, isFalse);
    expect(store.devices.single.name, 'Office MAG');
    expect(tester.widget<FilledButton>(
        find.byKey(const ValueKey('mag254-connect'))).onPressed, isNull);
  });

  testWidgets('MAG254 opens remote immediately after valid Connect',
      (tester) async {
    final store = _MemoryMagStore();
    store.devices.add(const Mag254Device(
      host: '192.168.1.80', name: 'Office MAG',
      deviceId: 'faeac9ec41c2f652', pairingCode: '259518',
    ));
    var connects = 0;
    await tester.pumpWidget(MaterialApp(home: Mag254RemoteScreen(
      store: store, initialHost: '192.168.1.80',
      connectOverride: (_) async { connects++; },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mag254-connect')));
    await tester.pumpAndSettle();
    expect(connects, 1);
    expect(find.byKey(const ValueKey('mag254-remote-view')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('mag254-host')), findsNothing);
    expect(find.byKey(const ValueKey('mag254-ok')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mag254-settings-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mag254-settings-view')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mag254-return-remote')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mag254-remote-view')),
        findsOneWidget);
    expect(connects, 1);
  });
}
