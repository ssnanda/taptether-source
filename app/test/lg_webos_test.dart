import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_webos_client.dart';
import 'package:taptether/lan_scan.dart';

void main() {
  test('LG hosts must be on private IPv4 LANs', () {
    expect(validLgHost('192.168.1.100'), isTrue);
    expect(validLgHost('10.0.0.8'), isTrue);
    expect(validLgHost('172.16.0.9'), isTrue);
    expect(validLgHost('8.8.8.8'), isFalse);
    expect(validLgHost('tv.example.com'), isFalse);
  });

  test('Pointer socket cannot redirect input to an unrelated host', () {
    expect(safeLgPointerUri(Uri.parse('wss://192.168.1.5:3001/socket'),
        '192.168.1.5'), isTrue);
    expect(safeLgPointerUri(Uri.parse('ws://192.168.1.6:3000/'),
        '192.168.1.5'), isFalse);
    expect(safeLgPointerUri(Uri.parse('https://192.168.1.5/'),
        '192.168.1.5'), isFalse);
  });

  test('LG SSDP signature filters unrelated devices', () {
    expect(isLgSsdpResponse('HTTP/1.1 200 OK\r\n'
        'ST: urn:lge-com:service:webos-second-screen:1\r\n'), isTrue);
    expect(isLgSsdpResponse('HTTP/1.1 200 OK\r\n'
        'ST: urn:schemas-upnp-org:device:MediaServer:1\r\n'), isFalse);
    // LG's generic UPnP service or webOS string is not SSAP proof.
    expect(isLgSsdpResponse('HTTP/1.1 200 OK\r\n'
        'ST: urn:lge-com:service:other:1\r\n'), isFalse);
    expect(isLgSsdpResponse('HTTP/1.1 200 OK\r\n'
        'LOCATION: http://device.local/webos.xml\r\n'), isFalse);
    expect(isLgSsdpResponse('HTTP/1.1 200 OK\r\n'
        'SERVER: Linux/3.0 webos-second-screen unrelated\r\n'), isFalse);
  });

  test('LG SSAP hello identifies TV without a pairing request', () {
    expect(isLgHelloResponse({
      'type': 'hello',
      'payload': {
        'protocolVersion': 1, 'deviceType': 'tv',
        'deviceOS': 'webOS', 'deviceUUID': 'tv123',
      },
    }), isTrue);
    expect(isLgHelloResponse({
      'type': 'hello', 'payload': {'deviceType': 'computer', 'deviceOS': 'webOS'},
    }), isFalse);
    expect(isLgHelloResponse({
      'type': 'hello', 'payload': {'deviceType': 'tv', 'deviceOS': 'linux'},
    }), isFalse);
    expect(isLgHelloResponse({'type': 'registered', 'payload': {}}), isFalse);
    expect(isLgHelloResponse({'type': 'hello', 'payload': {}}), isFalse);
    expect(isLgHelloResponse('not JSON'), isFalse);
  });

  test('LG discovery checks active /24 then remaining real Wi-Fi CIDR', () {
    final range = rangeFromWifi('192.168.68.70', '255.255.252.0')!;
    final targets = lgDiscoveryHosts(range);
    expect(targets, contains('192.168.68.62'));
    expect(targets.first, '192.168.68.1');
    expect(targets, contains('192.168.71.254'));
    expect(targets, isNot(contains('192.168.68.70')));
    expect(targets, isNot(contains('192.168.68.0')));
    expect(targets, isNot(contains('192.168.71.255')));
    expect(targets, isNot(contains('192.168.72.1')));
    expect(targets.length, 1021);
    expect(lgDiscoveryHosts(range, maxAddresses: 10).length, 10);
  });

  test('LG TV MAC address normalization rejects invalid hardware IDs', () {
    expect(canonicalLgMac('aa-bb-cc-dd-ee-ff'), 'AA:BB:CC:DD:EE:FF');
    expect(canonicalLgMac('AABBCCDDEEFF'), 'AA:BB:CC:DD:EE:FF');
    expect(canonicalLgMac('00:00:00:00:00:00'), isNull);
    expect(canonicalLgMac('FF:FF:FF:FF:FF:FF'), isNull);
    expect(canonicalLgMac('192.168.68.62'), isNull);
  });

  test('TV nickname, MAC and UUID survive secure-storage round trip', () {
    const tv = LgTvDevice(host: '192.168.68.62',
      name: 'Family Room TV',
      clientKey: 'saved-key',
      macAddress: 'AA:BB:CC:DD:EE:FF',
      deviceUuid: 'uuid-family-room',
    );
    final restored = LgTvDevice.fromJson(
        Map<String, dynamic>.from(tv.toJson()));
    expect(restored.name, 'Family Room TV');
    expect(restored.macAddress, 'AA:BB:CC:DD:EE:FF');
    expect(restored.deviceUuid, 'uuid-family-room');
    expect(restored.copyWith(name: 'Living Room').clientKey, 'saved-key');
  });

  test('LG registration reuses saved key and grants pointer control', () {
    final device = LgTvDevice(
        host: '192.168.1.5', name: 'Living Room', clientKey: 'known-key');
    final manifest = LgWebOsClient(device).registration();
    expect(manifest['client-key'], 'known-key');
    expect(manifest['pairingType'], 'PROMPT');
    final details = manifest['manifest'] as Map;
    expect(details['permissions'], contains('CONTROL_MOUSE_AND_KEYBOARD'));
    expect(details['permissions'], contains('CONTROL_INPUT_TEXT'));
  });

  test('Stored TV pairing round trips without changing identity', () {
    const tv = LgTvDevice(
      host: '192.168.1.5',
      name: 'Living Room',
      clientKey: 'secret-tv-key',
      tlsPin: 'ABCD',
      secure: true,
    );
    final copy = LgTvDevice.fromJson(Map<String, dynamic>.from(tv.toJson()));
    expect(copy.host, tv.host);
    expect(copy.name, tv.name);
    expect(copy.clientKey, tv.clientKey);
    expect(copy.tlsPin, tv.tlsPin);
    expect(copy.secure, isTrue);
  });
}
