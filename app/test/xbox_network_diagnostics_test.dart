import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lan_scan.dart';
import 'package:taptether/xbox_smartglass.dart';
import 'package:taptether/xbox_network_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('a /22 full scan includes all 4 neighboring /24 blocks', () {
    final range = rangeFromWifi('192.168.68.22', '255.255.252.0')!;
    final prefixes = xboxDiagnosticPrefixes(range);
    expect(prefixes.toSet(), {
      '192.168.68', '192.168.69', '192.168.70', '192.168.71',
    });
    expect(xboxDiagnosticHostCount(range), 1022);
    final targets = xboxScanTargets(range);
    expect(targets, contains('192.168.68.84'));
    expect(targets, contains('192.168.69.0'));
    expect(targets, contains('192.168.70.255'));
    expect(targets, isNot(contains('192.168.68.22')));
    expect(targets, isNot(contains('192.168.68.0')));
    expect(targets, isNot(contains('192.168.71.255')));
    expect(targets.length, 1021);
    expect(targets.toSet().length, targets.length);
  });

  test('scan remains bounded on larger networks', () {
    final range = rangeFromWifi('192.168.68.22', '255.255.240.0')!;
    expect(xboxDiagnosticPrefixes(range), hasLength(4));
    expect(xboxScanTargets(range).length, lessThanOrEqualTo(1024));
  });

  test('a focused Xbox IP remains visible after closing discovery', () async {
    final storage = XboxConsoleStore();
    expect(await storage.lastTargetIp(), isNull);
    await storage.saveLastTargetIp('192.168.68.84');
    expect(await storage.lastTargetIp(), '192.168.68.84');
    expect(() => storage.saveLastTargetIp('8.8.8.8'),
        throwsFormatException);
  });

  test('UDP counters distinguish sent/replied from authenticated pairing',
      () {
    final report = XboxDiscoveryStats();
    expect(report.sent, 0);
    expect(report.replies, 0);
    expect(report.compatible, 0);
    expect(report.malformed, 0);
  });
}
