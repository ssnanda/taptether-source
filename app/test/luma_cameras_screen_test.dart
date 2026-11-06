import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/luma_cameras_screen.dart';
import 'package:taptether/luma_nvr_client.dart';

class _MemoryLumaStore extends LumaSecureStore {
  LumaNvrSettings? settings;
  int writes = 0;

  @override
  Future<LumaNvrSettings?> load() async => settings;

  @override
  Future<void> save(LumaNvrSettings value) async {
    settings = value;
    writes++;
  }

  @override
  Future<void> remove() async => settings = null;
}

void main() {
  testWidgets('Save works offline, without attempting connection',
      (tester) async {
    final store = _MemoryLumaStore();
    await tester.pumpWidget(MaterialApp(
        home: LumaCamerasScreen(settingsOnly: true, store: store)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('luma-host')),
        'example.test:58000');
    await tester.enterText(find.byKey(const ValueKey('luma-username')),
        'camera-user');
    await tester.enterText(find.byKey(const ValueKey('luma-password')),
        'camera-password');
    await tester.tap(find.text('Server / SDK'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('luma-save-connection')));
    await tester.tap(find.byKey(const ValueKey('luma-save-connection')));
    await tester.pumpAndSettle();

    expect(store.writes, 1);
    expect(store.settings?.host, 'example.test');
    expect(store.settings?.port, 58000);
    expect(store.settings?.mode, LumaConnectionMode.sdkServer);
    expect(store.settings?.password, 'camera-password');
    expect(find.byKey(const ValueKey('luma-connect')), findsOneWidget);
    expect(find.textContaining('Saved securely'), findsOneWidget);
  });

  testWidgets('saved password can be reused when editing port',
      (tester) async {
    final store = _MemoryLumaStore()
      ..settings = LumaNvrSettings.fromInput(
          'nvr.local:8000', 'camera-user', 'retained-password',
          mode: LumaConnectionMode.sdkServer);
    await tester.pumpWidget(MaterialApp(
        home: LumaCamerasScreen(settingsOnly: true, store: store)));
    await tester.pumpAndSettle();
    expect(find.text('nvr.local:8000'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('luma-edit-connection')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('luma-host')),
        'nvr.local:58000');
    await tester.ensureVisible(find.byKey(const ValueKey('luma-save-connection')));
    await tester.tap(find.byKey(const ValueKey('luma-save-connection')));
    await tester.pumpAndSettle();
    expect(store.settings?.password, 'retained-password');
    expect(store.settings?.port, 58000);
    expect(find.byKey(const ValueKey('luma-connect')), findsOneWidget);
  });
}
