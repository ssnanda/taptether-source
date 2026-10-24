import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_thinq_api.dart';
import 'package:taptether/lg_thinq_device_screen.dart';
import 'package:taptether/lg_thinq_features.dart';

const fridge = LgThinQDevice(
  id: 'fridge-test', name: 'Refrigerator',
  type: 'DEVICE_REFRIGERATOR', model: '2REF11EIIN__2',
);
const dryer = LgThinQDevice(
  id: 'dryer-test', name: 'Dryer',
  type: 'DEVICE_DRYER', model: 'RV13U6AM8W_D_US_WIFI',
);

final refrigeratorProfile = {
  'property': {
    'doorStatus': [
      {'locationName': 'MAIN', 'doorState': {
        'type': 'enum', 'mode': ['r'],
      }},
    ],
    'powerSave': {
      'powerSaveEnabled': {'type': 'enum', 'mode': ['r']},
    },
    'refrigeration': {
      'expressMode': {
        'type': 'boolean', 'mode': ['r', 'w'],
        'value': {'w': [true, false]},
      },
      'expressModeName': {'type': 'enum', 'mode': ['r']},
      'freshAirFilter': {
        'type': 'enum', 'mode': ['r', 'w'],
        'value': {'w': ['AUTO', 'POWER']},
      },
    },
    'sabbath': {
      'sabbathMode': {'type': 'boolean', 'mode': ['r']},
    },
    'temperatureInUnits': [
      {
        'locationName': 'FREEZER',
        'targetTemperatureC': {
          'type': 'range', 'mode': ['r', 'w'],
          'value': {'w': {'min': -23, 'max': -15, 'step': 1}},
        },
        'targetTemperatureF': {
          'type': 'range', 'mode': ['r', 'w'],
          'value': {'w': {'min': -7, 'max': 5, 'step': 1}},
        },
      },
      {
        'locationName': 'FRIDGE',
        'targetTemperatureC': {
          'type': 'range', 'mode': ['r', 'w'],
          'value': {'w': {'min': 1, 'max': 7, 'step': 1}},
        },
        'targetTemperatureF': {
          'type': 'range', 'mode': ['r', 'w'],
          'value': {'w': {'min': 33, 'max': 43, 'step': 1}},
        },
      },
    ],
    'temperature': [
      {
        'locationName': 'FREEZER',
        'targetTemperature': {
          'type': 'range', 'mode': ['r', 'w'],
          'value': {'w': {'min': -23, 'max': -15}},
        },
      },
      {
        'locationName': 'FRIDGE',
        'targetTemperature': {
          'type': 'range', 'mode': ['r', 'w'],
          'value': {'w': {'min': 1, 'max': 7}},
        },
      },
    ],
    'waterFilterInfo': {
      'usedTime': {'type': 'number', 'mode': ['r']},
      'waterFilterState': {'type': 'enum', 'mode': ['r']},
    },
  },
};

final refrigeratorState = {
  'doorStatus': [
    {'locationName': 'MAIN', 'doorState': 'CLOSE'},
  ],
  'powerSave': {'powerSaveEnabled': 'Enabled'},
  'refrigeration': {
    'expressMode': false,
    'expressModeName': 'FREEZER',
    'freshAirFilter': 'REPLACE',
  },
  'sabbath': {'sabbathMode': false},
  'temperatureInUnits': [
    {
      'locationName': 'FREEZER',
      'targetTemperatureC': -23,
      'targetTemperatureF': -7,
    },
    {
      'locationName': 'FRIDGE',
      'targetTemperatureC': 1,
      'targetTemperatureF': 33,
    },
  ],
  'temperature': [
    {'locationName': 'FREEZER', 'targetTemperature': -7},
    {'locationName': 'FRIDGE', 'targetTemperature': 33},
  ],
  'waterFilterInfo': {'usedTime': 6, 'waterFilterState': 'REPLACE'},
};

final dryerProfile = {
  'property': {
    'operation': {
      'dryerOperationMode': {
        'type': 'enum', 'mode': ['r', 'w'],
        'value': {'w': ['START', 'STOP', 'POWER_OFF']},
      },
    },
    'remoteControlEnable': {
      'remoteControlEnabled': {
        'type': 'boolean', 'mode': ['r'],
      },
    },
    'runState': {
      'currentState': {'type': 'enum', 'mode': ['r']},
    },
    'timer': {
      'remainHour': {'type': 'number', 'mode': ['r']},
      'remainMinute': {'type': 'number', 'mode': ['r']},
      'totalHour': {'type': 'number', 'mode': ['r']},
      'totalMinute': {'type': 'number', 'mode': ['r']},
    },
  },
};

Map<String, Object?> dryerState({
  String state = 'POWER_OFF',
  bool remoteEnabled = false,
}) => {
  'operation': {},
  'remoteControlEnable': {
    'remoteControlEnabled': remoteEnabled,
  },
  'runState': {'currentState': state},
  'timer': {
    'remainHour': 0,
    'remainMinute': 57,
    'totalHour': 0,
    'totalMinute': 57,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('refrigerator: exact 14 properties, distinct compartments and units', () {
    final features = thinQFeatures(refrigeratorProfile, refrigeratorState);
    expect(features, hasLength(14));

    ThinQFeature find(String resource, String property, String zone) =>
        features.singleWhere((feature) =>
            feature.resource == resource &&
            feature.property == property &&
            feature.location == zone);

    final f = find('temperatureInUnits', 'targetTemperatureF', 'FRIDGE');
    expect(f.current, 33);
    expect(f.actionable, isTrue);
    expect(f.permits(44), isFalse);
    expect(f.command(36), {
      'temperatureInUnits': {
        'locationName': 'FRIDGE', 'targetTemperatureF': 36,
      },
    });

    final freezer = find('temperatureInUnits',
        'targetTemperatureF', 'FREEZER');
    expect(freezer.current, -7);
    expect(freezer.permits(-8), isFalse);

    // The generic field reads Fahrenheit but declares a Celsius range.
    // It must remain visible in diagnostics but never issue a command.
    for (final zone in ['FRIDGE', 'FREEZER']) {
      expect(find('temperature', 'targetTemperature', zone).actionable,
          isFalse);
    }
    final filter = features.singleWhere((f) =>
        f.property == 'freshAirFilter');
    expect(filter.current, 'REPLACE');
    expect(filter.options, ['AUTO', 'POWER']);
    expect(filter.permits('REPLACE'), isFalse);
    expect(filter.command('POWER'), {
      'refrigeration': {'freshAirFilter': 'POWER'},
    });
  });

  test('dryer: seven fields and off does not imply active cycle', () {
    final features = thinQFeatures(dryerProfile, dryerState());
    expect(features, hasLength(7));
    expect(features.singleWhere((f) => f.property == 'currentState')
        .current, 'POWER_OFF');
    expect(features.singleWhere((f) => f.property == 'remainMinute')
        .current, 57);
    expect(features.singleWhere((f) => f.property == 'remoteControlEnabled')
        .current, false);
  });

  testWidgets('refrigerator shows setpoints and requires reviewed command',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(950, 2300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final commands = <Map<String, Object?>>[];
    await tester.pumpWidget(MaterialApp(home: LgThinQDeviceScreen(
      device: fridge,
      fetchProfile: (_) async => refrigeratorProfile,
      fetchState: (_) async => refrigeratorState,
      sendControl: (_, payload) async => commands.add(payload),
    )));
    await tester.pumpAndSettle();
    expect(find.text('33°F'), findsOneWidget);
    expect(find.text('-7°F'), findsOneWidget);
    expect(find.text('Closed'), findsOneWidget);
    expect(find.text('Replace filter'), findsNothing);
    expect(find.byKey(const ValueKey('thinq-fresh-air-mode')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('thinq-setpoint-fridge')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('thinq-numeric-value')), '36');
    await tester.tap(find.text('Review command'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('thinq-confirm-control')));
    await tester.pumpAndSettle();
    expect(commands, [{
      'temperatureInUnits': {
        'locationName': 'FRIDGE', 'targetTemperatureF': 36,
      },
    }]);

    await tester.tap(find.text('Features'));
    await tester.pumpAndSettle();
    expect(find.text('Device features (14)'), findsOneWidget);
  });

  testWidgets('dryer power-off stays idle with remote start disabled',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(950, 1700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: LgThinQDeviceScreen(
      device: dryer,
      fetchProfile: (_) async => dryerProfile,
      fetchState: (_) async => dryerState(),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Powered off'), findsOneWidget);
    expect(find.text('57 min'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('minutes remaining'), findsNothing);
    expect(tester.widget<FilledButton>(
        find.byKey(const ValueKey('thinq-start'))).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('thinq-stop'))).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('thinq-power-off'))).onPressed, isNull);
    expect(find.textContaining('the dryer is not currently counting down'),
        findsOneWidget);
  });

  testWidgets('dryer starts only after Remote Start is reported enabled',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(950, 1700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final commands = <Map<String, Object?>>[];
    await tester.pumpWidget(MaterialApp(home: LgThinQDeviceScreen(
      device: dryer,
      fetchProfile: (_) async => dryerProfile,
      fetchState: (_) async => dryerState(
          state: 'READY', remoteEnabled: true),
      sendControl: (_, payload) async => commands.add(payload),
    )));
    await tester.pumpAndSettle();
    final start = tester.widget<FilledButton>(
        find.byKey(const ValueKey('thinq-start')));
    expect(start.onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('thinq-start')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('thinq-confirm-control')));
    await tester.pumpAndSettle();
    expect(commands, [
      {'operation': {'dryerOperationMode': 'START'}},
    ]);
  });
}
