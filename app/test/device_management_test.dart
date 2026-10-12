import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/discovery.dart';
import 'package:taptether/computer_store.dart';

void main() {
  test('discovery only accepts private local IPv4', () {
    for (final ip in ['192.168.68.87', '10.0.0.10', '172.31.2.2']) {
      expect(isPrivateIPv4(ip), isTrue, reason: ip);
    }
    for (final ip in ['8.8.8.8', '1.1.1.1', '172.32.1.2', 'not-an-ip']) {
      expect(isPrivateIPv4(ip), isFalse, reason: ip);
    }
  });

  test('saved profile can be serialized without losing TLS pins', () {
    final d = SavedComputer(
      id: SavedComputer.newId(), name: 'Ubuntu', host: '192.168.68.87',
      token: 'abcdefghijklmnopqrstuvwxy0123456789',
      fingerprint: List.filled(64, 'A').join(),
      platform: 'linux',
    );
    final restored = SavedComputer.fromJson(d.toJson());
    expect(restored.id, d.id);
    expect(restored.host, d.host);
    expect(restored.token, d.token);
    expect(restored.fingerprint, d.fingerprint);
  });
}
