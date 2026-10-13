import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/ubuntu_install_validation.dart';

void main() {
  test('accepts ordinary dotted private LAN IPv4', () {
    for (final ip in ['192.168.68.81', '192.168.68.87',
                      '10.0.0.5', '172.31.255.254']) {
      expect(validUbuntuLanIp(ip), isTrue, reason: ip);
    }
  });

  test('rejects incomplete, malformed and non-private addresses', () {
    for (final ip in [
      '', '1921686881', '192.168.68', '192.168.68.',
      '192.168.68.999', '192.168.68.1.2', '192..168.1',
      '.192.168.68.81', '192.168.068.81', '192.168.68.01',
      '192.168.68.1 ', '-1.2.3.4', '8.8.8.8', '172.32.0.1',
    ]) {
      expect(validUbuntuLanIp(ip), isFalse, reason: ip);
    }
  });
}
