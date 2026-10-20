import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_webos_client.dart';

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
