import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_thinq_tv_mac.dart';
import 'package:taptether/lg_webos_client.dart';

void main() {
  test('paired webOS IP identifies active Ethernet, not stale Wi-Fi', () {
    const payload = {
      'returnValue': true,
      'wifiInfo': {'macAddress': 'AA:BB:CC:DD:EE:01',
        'ipAddress': '192.168.68.10'},
      'wiredInfo': {'macAddress': 'AA:BB:CC:DD:EE:02',
        'ipAddress': '192.168.68.89', 'state': 'connected'},
    };
    expect(lgMacFromWebOsNetworkInfo(payload, '192.168.68.89'),
        'AA:BB:CC:DD:EE:02');
  });

  test('refuse ambiguous webOS MACs rather than waking wrong interface', () {
    const payload = {
      'returnValue': true,
      'wifiInfo': {'macAddress': 'AA:BB:CC:DD:EE:01'},
      'wiredInfo': {'macAddress': 'AA:BB:CC:DD:EE:02'},
    };
    expect(lgMacFromWebOsNetworkInfo(payload, '192.168.68.89'), isNull);
    expect(lgMacFromWebOsNetworkInfo({
      'wifiInfo': {'macAddress': 'AA:BB:CC:DD:EE:01'},
    }, '192.168.68.89'), 'AA:BB:CC:DD:EE:01');
    expect(lgMacFromWebOsNetworkInfo({
      'returnValue': false,
      'wifiInfo': {'macAddress': 'AA:BB:CC:DD:EE:01'},
    }, '192.168.68.89'), isNull);
  });

  test('ThinQ filters appliances and rejects conflicting network MACs', () {
    final hints = parseThinQTvMacHints({
      'devices': [
        {
          'deviceId': 'cloud-1',
          'deviceInfo': {
            'deviceType': 'DEVICE_TV',
            'alias': 'DadaDadi TV',
            'modelName': 'OLED65C4',
            'deviceUUID': 'webos-same-uuid',
            'macAddress': 'AA:BB:CC:DD:EE:01',
          },
        },
        {
          'deviceId': 'cloud-2',
          'deviceInfo': {
            'deviceType': 'DEVICE_WASHER',
            'alias': 'Washer',
            'macAddress': 'AA:BB:CC:DD:EE:02',
          },
        },
        {
          'deviceId': 'cloud-3',
          'deviceInfo': {
            'deviceType': 'DEVICE_TV',
            'alias': 'Other TV',
            'wifiMacAddress': 'AA:BB:CC:DD:EE:03',
            'ethernetMacAddress': 'AA:BB:CC:DD:EE:04',
          },
        },
      ]
    });
    expect(hints, hasLength(1));
    expect(hints.single.mac, 'AA:BB:CC:DD:EE:01');
    expect(hints.single.identifiers, contains('WEBOS-SAME-UUID'));
  });

  test('ThinQ requires immutable TV identity for automatic saving', () {
    final hints = parseThinQTvMacHints([
      {
        'deviceId': 'cloud-1',
        'deviceInfo': {
          'deviceType': 'DEVICE_TV',
          'alias': 'DadaDadi TV',
          'deviceUUID': 'webos-same-uuid',
          'macAddress': 'AA:BB:CC:DD:EE:01',
        },
      }
    ]);
    const tv = LgTvDevice(
      name: 'DadaDadi TV', host: '192.168.68.89',
      clientKey: 'paired', deviceUuid: 'webos-same-uuid',
    );
    expect(matchingThinQMacHint(tv, hints)?.mac,
        'AA:BB:CC:DD:EE:01');
    const noId = LgTvDevice(
      name: 'DadaDadi TV', host: '192.168.68.89',
      clientKey: 'paired',
    );
    expect(matchingThinQMacHint(noId, hints), isNull);
    expect(matchingThinQMacHint(noId, hints,
        requireVerification: false)?.mac, 'AA:BB:CC:DD:EE:01');
    expect(matchingThinQMacHint(const LgTvDevice(
      name: 'Family Room TV', host: '192.168.68.80',
      clientKey: 'paired', deviceUuid: 'different-tv',
    ), hints), isNull);
  });

  test('ThinQ cloud account IDs alone never prove TV identity', () {
    final hints = parseThinQTvMacHints([
      {
        'deviceId': 'matching-tv-uuid',
        'deviceInfo': {
          'deviceType': 'DEVICE_TV',
          'alias': 'DadaDadi TV',
          'macAddress': 'AA:BB:CC:DD:EE:01',
        },
      }
    ]);
    expect(matchingThinQMacHint(const LgTvDevice(
      name: 'DadaDadi TV', host: '192.168.68.89',
      clientKey: 'paired', deviceUuid: 'matching-tv-uuid',
    ), hints), isNull);
  });
}
