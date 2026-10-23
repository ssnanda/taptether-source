import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/device_diagnostics_screen.dart';

void main() {
  test('report omits bearer, secret and certificate fingerprint', () {
    final report = diagnosticReport(
      name: 'Lab Mac', kind: 'darwin', host: '192.168.68.11',
      timestamp: DateTime.utc(2026, 10, 22),
      details: {
        'Failure': 'Authorization: secret123 Bearer secretABC '
            'tlsPin=${'A' * 64}',
      },
    );
    expect(report, contains('192.168.68.11'));
    expect(report, contains('[REDACTED]'));
    expect(report, isNot(contains('secret123')));
    expect(report, isNot(contains('secretABC')));
    expect(report, isNot(contains('A' * 64)));
  });

  test('report retains actionable port state and timestamp', () {
    final report = diagnosticReport(
      name: 'LG', kind: 'lg', host: '192.168.68.30',
      timestamp: DateTime.utc(2026, 10, 22, 23, 59),
      details: {'TCP 3001': 'open (14 ms)', 'LAN subnet match': 'Yes'},
    );
    expect(report, contains('TCP 3001: open (14 ms)'));
    expect(report, contains('2026-10-22T23:59:00.000Z'));
    expect(report, contains('LAN subnet match: Yes'));
  });
}
