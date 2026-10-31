import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/resideo_api.dart';
import 'package:taptether/device_backup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  const thermostat = <String, dynamic>{
    'deviceID': 'LCC-123456',
    'deviceClass': 'Thermostat',
    'name': 'Office',
    'userDefinedDeviceName': 'Meeting Room',
    'isAlive': true,
    'units': 'Fahrenheit',
    'indoorTemperature': 73,
    'allowedModes': ['Off', 'Heat', 'Cool', 'Auto'],
    'minHeatSetpoint': 50,
    'maxHeatSetpoint': 90,
    'minCoolSetpoint': 50,
    'maxCoolSetpoint': 90,
    'changeableValues': {
      'mode': 'Off',
      'heatCoolMode': 'Heat',
      'heatSetpoint': 68,
      'coolSetpoint': 75,
      'thermostatSetpointStatus': 'NoHold',
      'autoChangeoverActive': false,
    },
    'settings': {
      'fan': {
        'allowedModes': ['On', 'Auto', 'Circulate'],
        'changeableValues': {'mode': 'Circulate'},
      },
    },
  };

  test('Parse Honeywell v2 locations and thermostat operating modes', () {
    final list = parseResideoLocations([
      {'locationID': 22562, 'name': 'Office',
       'devices': [thermostat, {'deviceID': 'leak1', 'deviceClass': 'LeakDetector'}]},
      {'locationID': '302000011002', 'name': 'Home',
       'devices': [
         {...thermostat, 'deviceID': 'cbfa2b27-c316-ef11-a9cd-6045bdbabfc1'},
       ]},
    ]);
    expect(list.length, 2);
    expect(list.first.temperature, 73);
    expect(list.first.system, 'Off'); // NOT heatCoolMode
    expect(list.first.fan, 'Circulate');
    expect(list.first.fanModes, contains('Circulate'));
    expect(list.first.locationId.isNotEmpty, isTrue);
    expect(list.last.locationId.isNotEmpty, isTrue);
  });

  test('Preserve changeable values and limit unsafe controls', () {
    final device = ResideoDevice.fromApi(thermostat, '22562', 'Office')!;
    expect(device.systemPayload('Cool'), {
      'mode': 'Cool',
      'heatSetpoint': 68.0,
      'coolSetpoint': 75.0,
      'autoChangeoverActive': false,
      'thermostatSetpointStatus': 'NoHold',
    });
    expect(device.adjustedSetpoint(heating: true, direction: 1), 69);
    expect(device.adjustedSetpoint(heating: false, direction: -1), 74);
    expect(device.supportsFan('Circulate'), isTrue);
    expect(() => device.systemPayload('EmergencyHeat'), throwsFormatException);
  });

  test('Resideo authorize URL uses Consumer Key and localhost callback', () {
    const redirect = 'http://localhost:7681/';
    final uri = ResideoConnection.authorizationUrl(
      'CONSUMER_KEY', redirect, state: 'random-state');
    expect(uri.scheme, 'https');
    expect(uri.host, 'api.honeywellhome.com');
    expect(uri.path, '/oauth2/authorize');
    expect(uri.queryParameters['client_id'], 'CONSUMER_KEY');
    expect(uri.queryParameters['response_type'], 'code');
    expect(uri.queryParameters['scope'], 'devices');
    expect(uri.queryParameters['redirect_uri'], redirect);
    expect(uri.queryParameters['state'], 'random-state');
    expect(ResideoConnection.authorizationCode(
      'http://localhost:7681/?code=SHORTCODE&state=random-state',
      redirect: redirect, state: 'random-state'), 'SHORTCODE');
    expect(() => ResideoConnection.authorizationCode(
      'http://localhost:7681/?code=SHORTCODE&state=bad-state',
      redirect: redirect, state: 'random-state'), throwsFormatException);
    expect(() => ResideoConnection.authorizationCode(
      'http://evil.test/?code=SHORTCODE&state=random-state',
      redirect: redirect, state: 'random-state'), throwsFormatException);
    expect(() => ResideoConnection.authorizationUrl(
      'KEY', 'http://public-host.test/callback'), throwsFormatException);
  });

  test('Consumer Key, Consumer Secret, Callback URL save without tokens',
      () async {
    const storage = FlutterSecureStorage();
    final connection = ResideoConnection(storage: storage);
    final before = await connection.credentials();
    expect(before.usable, isFalse);
    expect(before.redirectUri, ResideoConnection.defaultRedirect);
    await connection.save(const ResideoCredentials(
      apiKey: 'NEW_CONSUMER_KEY', apiSecret: 'NEW_CONSUMER_SECRET',
      accessToken: '', redirectUri: 'http://localhost:7681/',
    ));
    final c = await connection.credentials();
    expect(c.apiKey, 'NEW_CONSUMER_KEY');
    expect(c.apiSecret, 'NEW_CONSUMER_SECRET');
    expect(c.usable, isFalse);
    // Encrypted ciphertext, never searchable plaintext secrets.
    final values = await storage.readAll();
    final raw = values.toString();
    expect(raw, isNot(contains('NEW_CONSUMER_SECRET')));
    expect(raw, contains('taptether.resideo.device-vault.v2.data'));
    expect(await storage.read(
      key: 'taptether.honeywellhome.v1.apiSecret'), isNull);
    await connection.disconnect();
    expect((await connection.credentials()).usable, isFalse);
  });

  test('Previously saved on-device credentials are migrated and wiped',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'taptether.honeywellhome.v1.apiKey': 'OLD_KEY',
      'taptether.honeywellhome.v1.apiSecret': 'OLD_SECRET',
      'taptether.honeywellhome.v1.accessToken': 'OLD_ACCESS',
      'taptether.honeywellhome.v1.refreshToken': 'OLD_REFRESH',
      'taptether.honeywellhome.v1.redirectUri': 'http://localhost:7681/',
    });
    const storage = FlutterSecureStorage();
    final connection = ResideoConnection(storage: storage);
    final credentials = await connection.credentials();
    expect(credentials.apiSecret, 'OLD_SECRET');
    expect(credentials.usable, isTrue);
    expect(await storage.read(
        key: 'taptether.honeywellhome.v1.apiSecret'), isNull);
    expect((await storage.readAll()).toString(), isNot(contains('OLD_SECRET')));
  });

  test('Resideo credentials never enter even unencrypted device backups', () {
    expect(DeviceBackupCodec.supportedKey(
      'taptether.resideo.device-vault.v2.key'), isFalse);
    expect(DeviceBackupCodec.supportedKey(
      'taptether.resideo.device-vault.v2.data'), isFalse);
    expect(DeviceBackupCodec.supportedKey(
      'taptether.honeywellhome.v1.apiSecret'), isFalse);
  });

  test('Reject malformed inventory and missing consumer credentials',
      () async {
    expect(() => parseResideoLocations({'devices': []}), throwsFormatException);
    final c = ResideoConnection();
    await expectLater(
      c.save(const ResideoCredentials(
        apiKey: '', apiSecret: 'SECRET', accessToken: '',
        redirectUri: 'http://localhost:7681/')),
      throwsFormatException,
    );
  });
}
