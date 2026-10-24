import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_thinq_api.dart';
import 'package:taptether/lg_thinq_features.dart';
import 'package:taptether/lg_thinq_device_screen.dart';

void main() {
  const washer = LgThinQDevice(
    id: 'washer-1', name: 'Top Load Washer',
    type: 'DEVICE_WASHER', model: 'TLTU7CBP',
  );
  final washerProfile = {
    'property': [
      {
        'location': {'locationName': 'MAIN'},
        'runState': {
          'currentState': {
            'type':'enum', 'mode':['r'], 'value': {'r':['WASHING','END']}
          },
        },
        'remoteControlEnable': {
          'remoteControlEnabled': {'type':'boolean', 'mode':['r']},
        },
        'operation': {
          'washerOperationMode': {
            'type': 'enum', 'mode': ['r', 'w'],
            'value': {'w': ['POWER_OFF', 'REMOTE_START']}
          },
        },
        'timer': {
          'remainMinute': {'type':'range','mode':['r']}
        },
        'detergent': {
          'detergentSetting': {'type':'enum','mode':['r']}
        },
      }
    ],
  };
  final washerState = {
    'property': [
      {
        'location': {'locationName':'MAIN'},
        'runState': {'currentState':'WASHING'},
        'timer': {'remainMinute':35},
        'remoteControlEnable': {'remoteControlEnabled':false},
        'detergent': {'detergentSetting':'NORMAL'},
      }
    ],
  };

  test('washer: every profile resource and location is present', () {
    final features = thinQFeatures(washerProfile, washerState);
    expect(features.map((f) => f.property), containsAll([
      'currentState', 'washerOperationMode', 'remainMinute',
      'remoteControlEnabled', 'detergentSetting',
    ]));
    final state = features.singleWhere((f) => f.property == 'currentState');
    expect(state.current, 'WASHING');
    expect(state.actionable, isFalse);
    final operation = features.singleWhere(
      (f) => f.property == 'washerOperationMode');
    expect(operation.location, 'MAIN');
    expect(operation.actionable, isTrue);
    expect(operation.permits('REMOTE_START'), isTrue);
    expect(operation.permits('START_ANYTHING'), isFalse);
    expect(operation.command('REMOTE_START'), {
      'location': {'locationName':'MAIN'},
      'operation': {'washerOperationMode':'REMOTE_START'},
    });
    expect(thinQSummaryLine(features), 'WASHING · 35 min remaining');
  });

  test('dryer: all profile categories and readouts are displayed', () {
    final profile = {
      'property': {
        'runState': {'currentState':{'type':'enum','mode':['r']}},
        'timer': {'remainMinute':{'type':'number','mode':['r']}},
        'operation': {
          'dryerOperationMode':{
            'type':'enum','mode':['r','w'],
            'value':{'w':['POWER_OFF','REMOTE_START']},
          },
        },
      },
    };
    final status = {
      'runState': {'currentState':'DRYING'},
      'timer': {'remainMinute':47},
    };
    final features = thinQFeatures(profile, status);
    expect(features.length, 3);
    expect(thinQSummaryLine(features), 'DRYING · 47 min remaining');
    expect(features.singleWhere((f) => f.property == 'dryerOperationMode')
        .command('POWER_OFF'),
        {'operation':{'dryerOperationMode':'POWER_OFF'}});
  });

  test('refrigerator: independent compartments, temperature ranges, status',
      () {
    final profile = {
      'property': {
        'temperatureInUnits': [
          {
            'locationName': 'REFRIGERATOR',
            'targetTemperatureF': {
              'type':'range','mode':['r','w'],
              'unit':'F',
              'value':{'w': {'min':33,'max':46,'step':1}},
            },
          },
          {
            'locationName':'FREEZER',
            'targetTemperatureF':{
              'type':'range','mode':['r','w'],
              'value':{'w': {'min':-6,'max':8,'step':2}},
            },
          },
        ],
        'refrigeration': {
          'rapidFreeze':{
            'type':'boolean','mode':['r','w'],
          },
          'freshAirFilterRemainPercent':{
            'type':'number','mode':['r'],
          },
        },
        'doorStatus':[
          {'locationName':'REFRIGERATOR', 'doorState':{
            'type':'enum','mode':['r']}},
        ],
      },
    };
    final status = {
      'temperatureInUnits': [
        {'locationName':'REFRIGERATOR','targetTemperatureF':38},
        {'locationName':'FREEZER','targetTemperatureF':-2},
      ],
      'refrigeration': {'rapidFreeze': false,
        'freshAirFilterRemainPercent':72},
      'doorStatus':[
        {'locationName':'REFRIGERATOR','doorState':'CLOSED'},
      ],
    };
    final features = thinQFeatures(profile, status);
    final targets = features.where((f) => f.property == 'targetTemperatureF')
        .toList();
    expect(targets.length, 2);
    expect(targets.map((f) => f.current), containsAll([38, -2]));
    final freezer = targets.singleWhere((f) => f.location == 'FREEZER');
    expect(freezer.permits(0), isTrue);
    expect(freezer.permits(1), isFalse);
    expect(freezer.command(0), {
      'temperatureInUnits': {
        'locationName':'FREEZER', 'targetTemperatureF':0
      }
    });
    expect(features.singleWhere((f) => f.property == 'rapidFreeze')
        .command(true), {'refrigeration': {'rapidFreeze':true}});
    expect(features.map((f) => f.property),
      containsAll(['doorState', 'freshAirFilterRemainPercent']));
  });

  test('feature inventory excludes private fields and unsafe values', () {
    final f = thinQFeatures({
      'property': {
        'information': {
          'serialNumber': {'mode':['r'],'type':'string'},
          'password': {'mode':['r'],'type':'string'},
          'firmwareVersion': {'mode':['r'],'type':'string'},
        }
      }
    }, {'information': {
      'password':'SECRET', 'serialNumber':'PRIVATE',
      'firmwareVersion':'12.3',
    }});
    expect(f.map((e) => e.property), ['firmwareVersion']);
    expect(f.first.current, '12.3');
  });

  testWidgets('clicking enabled appliance opens all features and controls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map<String, Object?>>[];
    await tester.pumpWidget(MaterialApp(home: LgThinQDeviceScreen(
      device: washer,
      fetchProfile: (_) async => washerProfile,
      fetchState: (_) async => washerState,
      sendControl: (_, payload) async => sent.add(payload),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Top Load Washer'), findsWidgets);
    expect(find.textContaining('All reported features'), findsNothing);
    expect(find.text('Overview'), findsOneWidget);
    await tester.tap(find.text('Features'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Device features'), findsOneWidget);
    expect(find.byKey(const ValueKey('thinq-copy-features')),
        findsOneWidget);
    await tester.tap(find.text('Operation · MAIN'));
    await tester.pumpAndSettle();
    final operation = thinQFeatures(washerProfile, washerState)
        .singleWhere((f) => f.property == 'washerOperationMode');
    final button = find.byKey(ValueKey('thinq-control-${operation.identity}'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.textContaining('REMOTE START'), findsWidgets);
    await tester.tap(find.text('Review command'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('thinq-confirm-control')));
    await tester.pumpAndSettle();
    expect(sent, [
      {
        'location': {'locationName':'MAIN'},
        'operation': {'washerOperationMode':'POWER_OFF'},
      }
    ]);
  });
}
