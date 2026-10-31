import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/resideo_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));
  test('Read AJOps thermostat inventory and supported modes', () {
    final list = parseResideoDevices({'devices': [
      {'id': 'b', 'name': 'Office', 'location_id': '1',
       'location_name': 'HQ', 'indoor_temp': 72, 'set_temp': 70,
       'heat_setpoint': 68, 'cool_setpoint': 75,
       'mode': 'Cool', 'fan_mode': 'Circulate',
       'available_system_modes': ['Off', 'Cool', 'Heat'],
       'available_fan_modes': ['Auto', 'Circulate']},
      {'id': 'a', 'name': 'Breakroom'},
      {'name': 'missing ID'},
    ]});
    expect(list.length, 2);
    expect(list.first.name, 'Breakroom');
    expect(list.last.temperature, 72);
    expect(list.last.fanModes, contains('Circulate'));
  });
  test('Reject insecure URLs and malformed inventory', () {
    expect(() => parseResideoDevices({}), throwsFormatException);
    expect(() => ResideoConnection.validateUrl(
      'http://example.com/wp-json/ajcore/v1'), throwsFormatException);
    expect(() => ResideoConnection.validateUrl(
      'https://user:password@example.com/wp-json/ajcore/v1'), throwsFormatException);
    expect(ResideoConnection.validateUrl(
      'https://ncllcagents.com/wp-json/ajcore/v1/'), ResideoConnection.defaultUrl);
  });
  test('Integration is off until independently connected', () async {
    final c = ResideoConnection();
    expect(await c.session(), isNull);
    expect(await c.url(), ResideoConnection.defaultUrl);
  });
}
