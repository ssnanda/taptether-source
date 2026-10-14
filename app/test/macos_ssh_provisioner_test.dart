import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/macos_ssh_provisioner.dart';
import 'package:taptether/ubuntu_install_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test('distinguishes Mac architectures and rejects other operating systems', () {
    expect(macosArchiveArchitecture('Darwin', 'arm64'), 'arm64');
    expect(macosArchiveArchitecture('Darwin', 'x86_64'), 'amd64');
    expect(() => macosArchiveArchitecture('Linux', 'x86_64'),
        throwsA(isA<StateError>()));
    expect(() => macosArchiveArchitecture('Darwin', 'aarch64'),
        throwsA(isA<StateError>()));
  });

  test('reads Mac launchd pairing output while preserving security', () {
    final token = List.filled(48, 'a').join();
    final pin = List.filled(64, 'c').join();
    final data = macosPairingFromOutput(
      'TapTether: background agent installed.\n'
      'LAN IP: 192.168.68.77\n'
      'Port: 48321\nPairing token (PRIVATE): $token\n'
      'TLS SHA-256 fingerprint: $pin\n',
    );
    expect(data.token, token);
    expect(data.fingerprint, pin.toUpperCase());
    expect(() => macosPairingFromOutput('broken pairing token: $token'),
        throwsA(isA<StateError>()));
  });

  testWidgets('macOS update screen uses SSH and never requests sudo',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: UbuntuInstallScreen(
      initialHost: '192.168.68.77',
      isMac: true,
      updateOnly: true,
      onInstalled: (_) async => true,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Update macOS agent'), findsOneWidget);
    expect(find.text('macOS IP address'), findsOneWidget);
    expect(find.text('Update & reconnect'), findsOneWidget);
    expect(find.text('Sudo password (optional)'), findsNothing);
    expect(find.textContaining('Remote Login'), findsOneWidget);
  });

  testWidgets('Mac first install can be selected independently of updates',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: UbuntuInstallScreen(
      initialHost: '192.168.68.77',
      isMac: true,
      onInstalled: (_) async => true,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Install macOS agent'), findsOneWidget);
    expect(find.text('Install & pair'), findsOneWidget);
  });
}
