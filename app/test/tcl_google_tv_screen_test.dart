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
