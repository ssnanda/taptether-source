
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lan_scan.dart';
import 'package:taptether/network_location.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('home and office are remembered without location services', () async {
    final store = NetworkLocationStore();
    final home = rangeFromWifi(
      '192.168.68.101', '255.255.252.0', ssid: 'UPOSWIFI')!;
    final office = rangeFromWifi(
      '10.20.30.15', '255.255.255.0', ssid: 'OfficeNet')!;
    await store.assign(home, 'home');
    await store.assign(office, 'office');
    expect(await store.locationFor(home), 'home');
    expect(await store.locationFor(office), 'office');
    expect(await store.locationFor(null), isNull);
  });

  test('unassigned networks do not masquerade as home', () async {
    final store = NetworkLocationStore();
    expect(await store.locationFor(rangeFromWifi(
      '192.168.1.9', '255.255.255.0')), isNull);
  });
}
