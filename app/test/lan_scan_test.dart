import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lan_scan.dart';

void main() {
  test('scanner accepts only RFC1918 /24 prefixes', () {
    for (final prefix in ['192.168.68', '10.4.3', '172.16.0',
                         '172.31.255']) {
      expect(validPrivate24Prefix(prefix), isTrue, reason: prefix);
    }
    for (final prefix in ['8.8.8', '172.32.0', '192.168',
                         '192.168.68.1', '', '169.254.1']) {
      expect(validPrivate24Prefix(prefix), isFalse, reason: prefix);
    }
    expect(prefixFromIp('192.168.68.87'), '192.168.68');
    expect(prefixFromIp('8.8.8.8'), isNull);
  });

  test('service hints derive from observed open ports only', () {
    expect(const LanHost(
      ip: '192.168.68.87', hostname: 'mac.local',
      openPorts: [48321, 22],
    ).deviceHint, 'TapTether agent (likely)');
    expect(const LanHost(
      ip: '192.168.68.88', hostname: 'nas.local',
      openPorts: [445],
    ).deviceHint, 'File sharing / computer');
  });

  test('invalid scan target fails before network access', () async {
    await expectLater(scanPrivate24('8.8.8'), throwsFormatException);
    await expectLater(scanPrivate24('192.168.68', parallelism: 200),
        throwsFormatException);
  });
}
