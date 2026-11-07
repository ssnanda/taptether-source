import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/tcl_google_tv_screen.dart';
import 'package:taptether/tcl_google_tv_store.dart';

class _TestStore extends TclGoogleTvStore {
  List<TclGoogleTv> devices = [];

  @override
  Future<List<TclGoogleTv>> read() async => List.of(devices);

  @override
  Future<void> save(TclGoogleTv tv) async {
    devices.removeWhere((e) => e.host == tv.host);
    devices.add(tv);
  }

  @override
  Future<void> remove(String host) async {
    devices.removeWhere((e) => e.host == host);
  }
}

void main() {
  testWidgets('TCL TV can be saved offline; Connect requires pairing',
      (tester) async {
    final store = _TestStore();
    await tester.pumpWidget(MaterialApp(
        home: TclGoogleTvScreen(store: store)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(
        const ValueKey('tcl-google-tv-host')), '192.168.1.35');
    await tester.enterText(find.byKey(
        const ValueKey('tcl-google-tv-name')), 'Office TCL');
    await tester.tap(find.byKey(const ValueKey('tcl-google-tv-save')));
    await tester.pumpAndSettle();
    expect(store.devices.length, 1);
    expect(store.devices.single.name, 'Office TCL');
    expect(store.devices.single.paired, isFalse);
    expect(find.textContaining('Saved locally'), findsOneWidget);
    final connect = tester.widget<FilledButton>(
        find.byKey(const ValueKey('tcl-google-tv-connect')));
    expect(connect.onPressed, isNull);
    final pair = tester.widget<FilledButton>(
        find.byKey(const ValueKey('tcl-google-tv-pair')));
    expect(pair.onPressed, isNotNull);
  });

  testWidgets('Connect opens full remote, settings stay separate',
      (tester) async {
    final store = _TestStore();
    store.devices.add(const TclGoogleTv(
      host: '192.168.1.113',
      name: 'Living Room TCL',
      certificatePem: 'paired-certificate',
      privateKeyPem: 'paired-key',
      serverFingerprint: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    ));
    var handshakes = 0;
    await tester.pumpWidget(MaterialApp(
      home: TclGoogleTvScreen(
        initialHost: '192.168.1.113',
        store: store,
        connectOverride: (tv) async {
          expect(tv.host, '192.168.1.113');
          handshakes++;
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tcl-google-tv-connection-view')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tcl-google-tv-connect')));
    await tester.pumpAndSettle();
    expect(handshakes, 1);
    expect(find.byKey(const ValueKey('tcl-google-tv-remote-view')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('tcl-google-tv-host')), findsNothing);
    expect(find.byKey(const ValueKey('tcl-google-tv-save')), findsNothing);
    expect(find.byKey(const ValueKey('tcl-google-tv-ok')), findsOneWidget);

    await tester.tap(
        find.byKey(const ValueKey('tcl-google-tv-settings-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tcl-google-tv-connection-view')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('tcl-google-tv-remote-view')),
        findsNothing);
    await tester.tap(
        find.byKey(const ValueKey('tcl-google-tv-return-remote')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tcl-google-tv-remote-view')),
        findsOneWidget);
    expect(handshakes, 1);

    await tester.tap(
        find.byKey(const ValueKey('tcl-google-tv-disconnect')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tcl-google-tv-remote-view')),
        findsNothing);
    expect(find.byKey(const ValueKey('tcl-google-tv-connection-view')),
        findsOneWidget);
  });

  testWidgets('TCL TV UI rejects public IPs without saving',
      (tester) async {
    final store = _TestStore();
    await tester.pumpWidget(MaterialApp(
        home: TclGoogleTvScreen(store: store)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(
        const ValueKey('tcl-google-tv-host')), '8.8.8.8');
    await tester.tap(find.byKey(const ValueKey('tcl-google-tv-save')));
    await tester.pumpAndSettle();
    expect(store.devices, isEmpty);
    expect(find.textContaining('private local TV IP'), findsOneWidget);
  });
}
