import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/resideo_api.dart';

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

  test('Honeywell OAuth URL and code extraction use provider endpoint', () {
    final url = ResideoConnection.authorizationUrl(
      'KEY', 'https://example.com/resideo-callback');
    expect(url.host, 'api.honeywellhome.com');
    expect(url.path, '/oauth2/authorize');
    expect(url.queryParameters['client_id'], 'KEY');
    expect(ResideoConnection.authorizationCode(
      'https://example.com/resideo-callback?code=XYZ123&state=abc'), 'XYZ123');
    expect(() => ResideoConnection.authorizationUrl('KEY', 'http://insecure/'),
      throwsFormatException);
  });

  test('Developer token values persist exclusively in secure storage', () async {
    final connection = ResideoConnection();
    expect((await connection.credentials()).usable, isFalse);
    await connection.save(const ResideoCredentials(
      apiKey: 'KEY', apiSecret: 'SECRET', accessToken: 'ACCESS',
      refreshToken: 'REFRESH', redirectUri: 'https://example.com/callback',
    ));
    final c = await connection.credentials();
    expect(c.usable, isTrue);
    expect(c.apiKey, 'KEY');
    expect(c.refreshToken, 'REFRESH');
    await connection.disconnect();
    expect((await connection.credentials()).usable, isFalse);
  });

  test('Reject AJCore-shaped payloads and missing API keys', () async {
    expect(() => parseResideoLocations({'devices': []}), throwsFormatException);
    final c = ResideoConnection();
    expect(() => c.save(const ResideoCredentials(
        apiKey: '', accessToken: 'ACCESS')), throwsFormatException);
  });
}
