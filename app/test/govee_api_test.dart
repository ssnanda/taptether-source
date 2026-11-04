import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/govee_api.dart';

void main() {
  final sample = <String, dynamic>{
    'sku': 'H605C',
    'device': 'AB:CD',
    'deviceName': 'Desk light',
    'type': 'devices.types.light',
    'capabilities': [
      {'type': 'devices.capabilities.on_off', 'instance': 'powerSwitch'},
      {'type': 'devices.capabilities.range', 'instance': 'brightness',
        'parameters': {'range': {'min': 1, 'max': 100}}},
      {'type': 'devices.capabilities.color_setting', 'instance': 'colorRgb'},
      {'type': 'devices.capabilities.dynamic_scene', 'instance': 'lightScene',
        'parameters': {'options': [
          {'name': 'Calm', 'value': 1}, {'name': 'Focus', 'value': 2},
        ]}},
    ],
  };

  test('discovers capabilities and scenes from the official response', () {
    final device = GoveeDevice.fromJson(sample);
    expect(device.name, 'Desk light');
    expect(device.isLight, isTrue);
    expect(device.hasPower, isTrue);
    expect(device.hasBrightness, isTrue);
    expect(device.hasColor, isTrue);
    expect(device.hasTemperature, isFalse);
    expect(device.hasScenes, isTrue);
    expect(device.capability('devices.capabilities.dynamic_scene',
        'lightScene')!.options, [('Calm', 1), ('Focus', 2)]);
  });

  test('merges status response without dropping static capabilities', () {
    final device = GoveeDevice.fromJson(sample).withState({
      'capabilities': [
        {'instance': 'online', 'state': {'value': true}},
        {'instance': 'powerSwitch', 'state': {'value': 1}},
        {'instance': 'brightness', 'state': {'value': 75}},
        {'instance': 'colorRgb', 'state': {'value': 0xff0099}},
      ],
    });
    expect(device.online, true);
    expect(device.powered, true);
    expect(device.brightness, 75);
    expect(device.color, 0xff0099);
    expect(device.hasPower, true);
    expect(device.withLocal(brightness: 20).brightness, 20);
  });

  test('H5054 sleeping sensor does not get a false offline label', () {
    final leak = GoveeDevice.fromJson({
      'sku': 'H5054',
      'device': 'AB:CD',
      'deviceName': 'Kitchen Sink',
      'type': 'devices.types.sensor',
      'capabilities': [],
    }).withState({
      'capabilities': [
        {'type': 'devices.capabilities.online',
         'instance': 'online', 'state': {'value': false}},
      ],
    });
    expect(leak.online, false);
    expect(leak.availabilityLabel, 'Status unavailable via API');
    expect(leak.hasPower, false);
  });

  test('API sensor temperature and humidity are parsed when supplied', () {
    final climate = GoveeDevice.fromJson({
      'sku': 'H5140', 'device': 'A1', 'deviceName': 'Office',
      'type': 'devices.types.air_quality_monitor', 'capabilities': [],
    }).withState({
      'capabilities': [
        {'instance': 'online', 'state': {'value': true}},
        {'instance': 'sensorTemperature', 'state': {'value': 75.4}},
        {'instance': 'sensorHumidity', 'state': {'value': 49.1}},
      ],
    });
    expect(climate.availabilityLabel, 'Online');
    expect(climate.sensorTemperature, 75.4);
    expect(climate.sensorHumidity, 49.1);
    expect(climate.withLocal(powered: true).sensorTemperature, 75.4);
  });

  test('unknown capabilities do not create unsafe controls', () {
    final sensor = GoveeDevice.fromJson({
      'sku': 'H5140', 'device': 'SENSOR', 'type': 'devices.types.sensor',
      'capabilities': [
        {'type': 'devices.capabilities.property',
          'instance': 'sensorTemperature'},
      ],
    });
    expect(sensor.hasPower, false);
    expect(sensor.hasColor, false);
    expect(sensor.hasBrightness, false);
  });

  test('offline state is preserved when updating local controls', () {
    final offline = GoveeDevice.fromJson(sample).withState({
      'capabilities': [
        {'instance': 'online', 'state': {'value': false}},
      ],
    });
    expect(offline.withLocal(powered: true).online, false);
  });
}
