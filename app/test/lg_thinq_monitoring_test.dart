import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_thinq_api.dart';
import 'package:taptether/lg_thinq_cycle_history.dart';
import 'package:taptether/lg_thinq_device_screen.dart';
import 'package:taptether/lg_thinq_features.dart';
import 'package:taptether/lg_thinq_energy_panel.dart';

final _profile = {
  'property': [{
    'location': {'locationName': 'MAIN'},
    'runState': {'currentState': {'type': 'enum', 'mode': ['r']}},
    'timer': {
      'remainMinute': {'type': 'number', 'mode': ['r']},
      'totalMinute': {'type': 'number', 'mode': ['r']},
      'relativeHourToStart': {
        'type': 'range', 'mode': ['r', 'w'],
        'value': {'w': {'min': 0, 'max': 19, 'step': 1}},
      },
    },
    'cycle': {'cycleCount': {'type': 'number', 'mode': ['r']}},
    'remoteControlEnable': {
      'remoteControlEnabled': {'type': 'boolean', 'mode': ['r']},
    },
    'operation': {'washerOperationMode': {
      'type': 'enum', 'mode': ['r', 'w'],
      'value': {'w': ['START', 'STOP', 'POWER_OFF']},
    }},
  }],
};

Map<String, Object?> _live(String state, int remaining) => {
  'property': [{
    'location': {'locationName': 'MAIN'},
    'runState': {'currentState': state},
    'timer': {'remainMinute': remaining, 'totalMinute': 35,
      'relativeHourToStart': 0},
    'cycle': {'cycleCount': 47},
    'remoteControlEnable': {'remoteControlEnabled': false},
  }],
};

const _washer = LgThinQDevice(
  id: 'model-tltu7cbp', name: 'Top Load Washer',
  type: 'DEVICE_WASHER', model: 'TLTU7CBP',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('47 previously completed cycles do not create fabricated history', () {
    final off = thinQFeatures(_profile, _live('POWER_OFF', 0));
    expect(observeThinQCycle([], off, DateTime(2026, 10, 23)), isEmpty);
    expect(thinQInteger(off, 'cycleCount'), 47);
    expect(thinQMinutes(off, 'totalHour', 'totalMinute'), 35);
  });

  test('only observed cycle starts and completion create local history', () {
    final at = DateTime(2026, 10, 23, 20);
    final started = observeThinQCycle(
      [], thinQFeatures(_profile, _live('WASHING', 35)), at);
    expect(started.single.active, isTrue);
    expect(started.single.samples, 1);
    expect(started.single.initialCount, 47);
    final rinsing = observeThinQCycle(started,
        thinQFeatures(_profile, _live('RINSING', 12)),
        at.add(const Duration(minutes: 23)));
    expect(rinsing.single.samples, 2);
    expect(rinsing.single.lastRemainingMinutes, 12);
    final done = observeThinQCycle(rinsing,
        thinQFeatures(_profile, _live('END', 0)),
        at.add(const Duration(minutes: 35)));
    expect(done.single.active, isFalse);
    expect(done.single.outcome, 'finished');
    expect(done.single.endedAt, isNotNull);
    expect(done.single.startedAt, at);
    expect(observeThinQCycle(done, thinQFeatures(
        _profile, _live('POWER_OFF', 0)),
        at.add(const Duration(hours: 1))).length, 1);
  });

  test('missed completion is labeled unknown, not falsely finished', () {
    final time = DateTime(2026, 10, 23);
    final started = observeThinQCycle([],
        thinQFeatures(_profile, _live('SPINNING', 3)), time);
    final stopped = observeThinQCycle(started,
        thinQFeatures(_profile, _live('POWER_OFF', 0)),
        time.add(const Duration(hours: 1)));
    expect(stopped.single.outcome, 'stopped/unknown');
  });

  test('journal persists only observed readings in secure local storage',
      () async {
    final store = ThinQCycleHistoryStore();
    final time = DateTime(2026, 10, 23, 21);
    await store.record(_washer.id,
        thinQFeatures(_profile, _live('WASHING', 32)), time);
    expect((await store.read(_washer.id)).single.samples, 1);
    await store.record(_washer.id,
        thinQFeatures(_profile, _live('END', 0)),
        time.add(const Duration(minutes: 32)));
    final records = await store.read(_washer.id);
    expect(records.single.outcome, 'finished');
    await store.clear(_washer.id);
    expect(await store.read(_washer.id), isEmpty);
  });

  testWidgets('overview is default; history and features are separate tabs',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(950, 1900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: LgThinQDeviceScreen(
      device: _washer,
      fetchProfile: (_) async => _profile,
      fetchState: (_) async => _live('WASHING', 20),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Washing'), findsOneWidget);
    expect(find.text('minutes remaining'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.byKey(const ValueKey('thinq-detail-tabs')), findsOneWidget);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('Cycle history'), findsOneWidget);
    expect(find.textContaining('observed sessions'), findsOneWidget);
    await tester.tap(find.text('Features'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Device features'), findsOneWidget);
    expect(find.byKey(const ValueKey('thinq-group-Run State · MAIN')),
        findsOneWidget);
  });

  testWidgets('energy absence shows unavailable rather than zero kWh',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: LgThinQEnergyPanel(
        device: _washer,
        fetchProfile: (_) async => {'property': []},
        fetchUsage: (id, name, period, start, end) async => {},
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Energy usage is not exposed'), findsOneWidget);
  });
}
