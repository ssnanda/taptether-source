import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/smartthings_family_hub.dart';
import 'package:taptether/smartthings_family_hub_screen.dart';

class _MemoryHubStore extends FamilyHubStore {
  FamilyHubSettings config = const FamilyHubSettings();
  int saved = 0;
  @override Future<FamilyHubSettings> read() async => config;
  @override Future<void> save(FamilyHubSettings next) async {
    config = next;
    saved++;
  }
}

void main() {
  testWidgets('Family Hub saved IP and token do not require a connection',
      (tester) async {
    final store = _MemoryHubStore();
    await tester.pumpWidget(MaterialApp(
      home: SmartThingsFamilyHubScreen(store: store),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('family-hub-ip')),
        '192.168.1.88');
    await tester.enterText(find.byKey(const ValueKey('family-hub-token')),
        'stored-token');
    await tester.ensureVisible(find.byKey(const ValueKey('family-hub-save')));
    await tester.tap(find.byKey(const ValueKey('family-hub-save')));
    await tester.pumpAndSettle();
    expect(store.saved, 1);
    expect(store.config.localIp, '192.168.1.88');
    expect(store.config.personalToken, 'stored-token');
    expect(find.textContaining('Saved to iPhone Keychain'), findsOneWidget);
    final connect = tester.widget<FilledButton>(
        find.byKey(const ValueKey('family-hub-connect')));
    expect(connect.onPressed, isNotNull);
  });

  testWidgets('rejects public IPs without losing the existing token',
      (tester) async {
    final store = _MemoryHubStore();
    store.config = const FamilyHubSettings(
        localIp: '192.168.1.88', personalToken: 'saved');
    await tester.pumpWidget(MaterialApp(
      home: SmartThingsFamilyHubScreen(store: store),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('family-hub-ip')),
        '8.8.8.8');
    await tester.ensureVisible(find.byKey(const ValueKey('family-hub-save')));
    await tester.tap(find.byKey(const ValueKey('family-hub-save')));
    await tester.pumpAndSettle();
    expect(store.saved, 0);
    expect(store.config.localIp, '192.168.1.88');
    expect(store.config.personalToken, 'saved');
  });
}
