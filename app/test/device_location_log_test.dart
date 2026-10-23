import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/device_location_log.dart';

void main() {
  test('location history keys never contain device IDs or secrets', () {
    final key = DeviceLocationLog.storageKey('lg:my-device-identity');
    expect(key, startsWith('taptether.locate.history.v1.'));
    expect(key, isNot(contains('my-device-identity')));
  });

  test('location history is bounded and tolerates invalid storage', () {
    expect(DeviceLocationLog.parse('not-json'), isEmpty);
    expect(DeviceLocationLog.parse('{}'), isEmpty);
    final items = List.generate(50, (i) => 'event $i');
    expect(DeviceLocationLog.parse(jsonEncode(items)).length, 24);
  });

  test('location messages remain short and have no line breaks', () {
    expect(DeviceLocationLog.safeMessage('DNS checked\nother text'),
        'DNS checked other text');
    expect(DeviceLocationLog.safeMessage(List.filled(250, 'a').join()).length, 150);
  });
}
