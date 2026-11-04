import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/govee_api.dart';
import 'package:taptether/govee_placement.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  GoveeDevice device(String name, String id) => GoveeDevice.fromJson({
    'sku': 'H5054', 'device': id, 'deviceName': name,
    'type': 'devices.types.sensor', 'capabilities': <Map<String, dynamic>>[],
  });

  test('location is preferred, room is fallback, unassigned is last', () {
    final devices = [
      device('UPOS Kitchen', '1'),
      device('Mens-1', '2'),
      device('Pantry main cutoff', '3'),
      device('Kitchen Sink', '4'),
    ];
    final places = <String, GoveePlacement>{
      goveeDeviceKey(devices[0]):
          const GoveePlacement(location: 'Office', room: 'Kitchen'),
      goveeDeviceKey(devices[1]):
          const GoveePlacement(location: 'Office', room: 'Restroom'),
      goveeDeviceKey(devices[2]):
          const GoveePlacement(room: 'Pantry'),
    };
    final groups = goveeGroups(devices, places);
    expect(groups.keys.toList(), ['Office', 'Pantry', 'Unassigned']);
    expect(groups['Office']!.map((d) => d.name).toList(),
      ['Mens-1', 'UPOS Kitchen']);
    expect(groups['Pantry']!.single.name, 'Pantry main cutoff');
    expect(groups['Unassigned']!.single.name, 'Kitchen Sink');
  });

  test('device organization persists across screen visits', () async {
    final store = GoveePlacementStore();
    final sink = device('Kitchen Sink', 'AA:BB');
    final id = goveeDeviceKey(sink);
    await store.save({
      id: const GoveePlacement(room: 'Kitchen'),
      'empty': const GoveePlacement(),
    });
    final saved = await GoveePlacementStore().read();
    expect(saved[id]!.room, 'Kitchen');
    expect(saved[id]!.location, '');
    expect(saved.containsKey('empty'), isFalse);
    await store.save({
      ...saved,
      id: const GoveePlacement(location: 'Home', room: 'Kitchen'),
    });
    expect((await store.read())[id]!.location, 'Home');
  });

  test('missing and malformed organization is handled safely', () async {
    final store = GoveePlacementStore();
    expect(await store.read(), isEmpty);
    const storage = FlutterSecureStorage();
    await storage.write(key: GoveePlacementStore.key, value: '{broken');
    expect(await store.read(), isEmpty);
    await storage.write(key: GoveePlacementStore.key,
        value: '{"abc":{"room": "  Master bath  ","location": ""}}');
    expect((await store.read())['abc']!.room, 'Master bath');
  });
}
