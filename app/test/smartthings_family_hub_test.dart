import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lan_scan.dart';
import 'package:taptether/smartthings_family_hub.dart';
import 'package:taptether/device_backup.dart';

class _MemoryStore extends FamilyHubStore {
  _MemoryStore(this.value);
  FamilyHubSettings value;
  @override Future<FamilyHubSettings> read() async => value;
  @override Future<void> save(FamilyHubSettings next) async {
    value = next;
  }
}

void main() {
  test('Family Hub connection details are supported by device backups', () {
    expect(DeviceBackupCodec.supportedKey(FamilyHubStore.key), isTrue);
  });

  test('TCP 17654 is only an unverified Samsung Family Hub hint', () {
    const host = LanHost(ip: '192.168.1.88', hostname: '192.168.1.88',
        openPorts: [17654]);
    expect(host.deviceType, contains('Possible Samsung Family Hub'));
    expect(host.deviceHint, contains('identity unverified'));
    expect(lanScanPorts, contains(17654));
    expect(host.displayName, contains('unverified'));
  });

  test('credentials and user-confirmed IP survive Keychain JSON roundtrip', () {
    const original = FamilyHubSettings(
      localIp: '192.168.1.88',
      personalToken: 'private-test-token',
      clientId: 'client-id',
      clientSecret: 'private-secret',
      redirectUri: 'https://example.test/callback',
    );
    final restored = FamilyHubSettings.fromJson(original.toJson());
    expect(restored.localIp, '192.168.1.88');
    expect(restored.personalToken, 'private-test-token');
    expect(restored.clientSecret, 'private-secret');
    expect(restored.connected, isTrue);
  });

  test('refrigerator discovery does not confuse Samsung TVs with fridges', () {
    expect(FamilyHubDevice.looksLikeRefrigerator(
        {'deviceId': 'fridge', 'label': 'Samsung Family Hub'}), isTrue);
    expect(FamilyHubDevice.looksLikeRefrigerator(
        {'deviceId': 'tv', 'label': 'Samsung Smart TV'}), isFalse);
    expect(FamilyHubDevice.looksLikeRefrigerator({
      'deviceId': 'fridge', 'components': [
        {'id': 'main'}, {'id': 'freezer'},
      ],
    }), isTrue);
  });

  test('status only shows capabilities actually provided by SmartThings', () {
    final status = FamilyHubStatus.fromJson({
      'components': {
        'cooler': {
          'temperatureMeasurement': {
            'temperature': {'value': 3.2, 'unit': 'C'},
          },
          'contactSensor': {
            'contact': {'value': 'closed'},
          },
        },
        'freezer': {
          'temperatureMeasurement': {
            'temperature': {'value': -18, 'unit': 'C'},
          },
        },
        'main': {
          'unsupportedCapability': {'unrecognized': {'value': 'skip'}},
        },
      },
    });
    final rows = status.readings();
    expect(rows.map((r) => r.label), contains('cooler · Temperature'));
    expect(rows.map((r) => r.value), contains('3.2 C'));
    expect(rows.map((r) => r.value), contains('-18 C'));
    expect(rows.map((r) => r.value), contains('closed'));
    expect(rows.any((r) => r.value == 'skip'), isFalse);
  });

  test('read-only SmartThings discovery uses saved bearer token', () async {
    final store = _MemoryStore(const FamilyHubSettings(
        localIp: '192.168.1.88', personalToken: 'samsung-token'));
    final calls = <Uri>[];
    final client = FamilyHubClient(store: store,
      transport: (method, uri, headers, body) async {
        calls.add(uri);
        expect(method, 'GET');
        expect(headers['Authorization'], 'Bearer samsung-token');
        if (uri.path == '/v1/devices') {
          return {
            'items': [
              {'deviceId': 'fridge01', 'label': 'Samsung Family Hub'},
              {'deviceId': 'tv01', 'label': 'Samsung Smart TV'},
            ],
          };
        }
        return {
          'components': {
            'main': {
              'contactSensor': {'contact': {'value': 'closed'}},
            },
          },
        };
      },
    );
    final found = await client.refrigerators();
    expect(found.map((d) => d.id).toList(), ['fridge01']);
    final state = await client.status(found.single.id);
    expect(state.readings().single.value, 'closed');
    expect(calls.map((u) => u.path),
        ['/v1/devices', '/v1/devices/fridge01/status']);
  });

  test('OAuth refresh rotates and stores token pair before API request',
      () async {
    final store = _MemoryStore(FamilyHubSettings(
      localIp: '192.168.1.88', clientId: 'client-id',
      clientSecret: 'secret', redirectUri: 'https://example.test/callback',
      accessToken: 'old-token', refreshToken: 'old-refresh',
      expiresUtc: DateTime.now().toUtc()
          .subtract(const Duration(minutes: 5)).toIso8601String(),
    ));
    var refreshCalls = 0;
    final client = FamilyHubClient(store: store,
      transport: (method, uri, headers, body) async {
        if (uri.path == '/v1/oauth/token') {
          refreshCalls++;
          expect(method, 'POST');
          expect((body as Map)['refresh_token'], 'old-refresh');
          return {
            'access_token': 'new-token',
            'refresh_token': 'new-refresh',
            'expires_in': 86000,
          };
        }
        expect(headers['Authorization'], 'Bearer new-token');
        return {'items': []};
      },
    );
    expect(await client.refrigerators(), isEmpty);
    expect(refreshCalls, 1);
    expect(store.value.accessToken, 'new-token');
    expect(store.value.refreshToken, 'new-refresh');
    expect(store.value.personalToken, isEmpty);
  });

  test('OAuth callback enforces state and registered redirect URL', () {
    const registered = 'https://example.test/oauth';
    const state = 'abcdefghijklmnopqrstuvwxyz123456';
    final settings = FamilyHubSettings(
        clientId: 'client', clientSecret: 'secret',
        redirectUri: registered);
    final url = FamilyHubClient.authorizeUrl(settings, state);
    expect(url.host, 'api.smartthings.com');
    expect(url.path, '/v1/oauth/authorize');
    expect(url.queryParameters['scope'], 'r:devices:*');
    expect(FamilyHubClient.codeFromCallback(
        registered + '?code=abc&state=' + state, registered, state), 'abc');
    expect(() => FamilyHubClient.codeFromCallback(
        registered + '?code=abc&state=wrong', registered, state),
        throwsFormatException);
    expect(() => FamilyHubClient.codeFromCallback(
        'https://attacker.test/oauth?code=abc&state=' + state,
        registered, state), throwsFormatException);
  });
}
