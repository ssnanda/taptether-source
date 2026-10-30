import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:workmanager/workmanager.dart';

import 'fridge_temperature.dart';
import 'lg_thinq_api.dart';

const fridgeBackgroundJob = 'com.taptether.taptether.fridge-watch';
const _alertKey = 'taptether.fridge.alerts.enabled.v1';
const _baselinePrefix = 'taptether.fridge.alerts.baseline.v1.';
const _lastCheckedPrefix = 'taptether.fridge.alerts.checked.v1.';
const _intervalPrefix = 'taptether.fridge.alerts.interval.v1.';

/// Short intervals are useful when TapTether is open for testing.
/// Background work on iOS is scheduled by the OS, not by this timer.
const fridgeCheckIntervals = <int>[1, 5, 15, 30, 60];
const fridgeDefaultCheckMinutes = 15;

bool fridgeCheckIsDue(DateTime now, DateTime? lastChecked, int minutes) =>
    lastChecked == null ||
    !now.isBefore(lastChecked.add(Duration(minutes: minutes)));

int fridgeBackgroundMinutes(Iterable<int> configured) {
  final intervals = configured.toList();
  if (intervals.isEmpty) return fridgeDefaultCheckMinutes;
  final shortest = intervals.reduce((a, b) => a < b ? a : b);
  return shortest < 15 ? 15 : shortest;
}

@pragma('vm:entry-point')
void taptetherBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != fridgeBackgroundJob &&
        task != Workmanager.iOSBackgroundTask) {
      return true;
    }
    DartPluginRegistrant.ensureInitialized();
    try {
      await FridgeAlerts.instance.checkAll();
      return true;
    } catch (_) {
      // Workmanager can retry transient connection/plugin errors.
      return false;
    }
  });
}

class FridgeAlerts {
  FridgeAlerts._();
  static final FridgeAlerts instance = FridgeAlerts._();
  final _store = const FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  final _notifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool _checkingForeground = false;

  Future<void> initialize({bool allowPermissions = false}) async {
    if (!_initialized) {
      await _notifications.initialize(settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ));
      _initialized = true;
    }
    if (allowPermissions) {
      bool? granted;
      if (Platform.isIOS) {
        granted = await _notifications.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
          alert: true, badge: false, sound: true,
        );
      } else if (Platform.isAndroid) {
        granted = await _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
      if (granted == false) {
        throw StateError('Notifications are blocked. Enable them in '
            'phone Settings before turning on refrigerator alerts.');
      }
    }
  }

  Future<Set<String>> enabledDevices() async {
    final raw = await _store.read(key: _alertKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is List
          ? decoded.whereType<String>().toSet() : {};
    } catch (_) {
      return {};
    }
  }

  Future<bool> isEnabled(String id) async =>
      (await enabledDevices()).contains(id);

  Future<int> intervalMinutes(String id) async {
    final raw = await _store.read(key: '$_intervalPrefix$id');
    final configured = int.tryParse(raw ?? '');
    return configured != null && fridgeCheckIntervals.contains(configured)
        ? configured : fridgeDefaultCheckMinutes;
  }

  Future<void> setIntervalMinutes(String id, int minutes) async {
    if (!fridgeCheckIntervals.contains(minutes)) {
      throw ArgumentError.value(minutes, 'minutes', 'Unsupported interval');
    }
    if (!(await isEnabled(id))) {
      throw StateError('Enable refrigerator alerts before setting an interval.');
    }
    final key = '$_intervalPrefix$id';
    final previous = await _store.read(key: key);
    await _store.write(key: key, value: '$minutes');
    try {
      await syncBackgroundTask();
    } catch (_) {
      if (previous == null) {
        await _store.delete(key: key);
      } else {
        await _store.write(key: key, value: previous);
      }
      rethrow;
    }
  }

  /// Checks only due saved refrigerators. Never starts a scan or a
  /// perpetual iOS background timer; the owner calls this while foreground.
  Future<void> checkForegroundDue() async {
    if (_checkingForeground) return;
    _checkingForeground = true;
    try {
      final enabled = await enabledDevices();
      if (enabled.isEmpty) return;
      final devices = await LgThinQStorage().enabledDevices();
      for (final device in devices) {
        if (!enabled.contains(device.id) ||
            !device.type.toUpperCase().contains('REFRIGERATOR')) {
          continue;
        }
        final due = fridgeCheckIsDue(
          DateTime.now(), await lastChecked(device.id),
          await intervalMinutes(device.id),
        );
        if (!due) continue;
        try {
          await checkDevice(device);
        } catch (_) {
          // Failed checks do not advance lastChecked, so they can retry.
        }
      }
    } finally {
      _checkingForeground = false;
    }
  }

  Future<Object?> _fetchState(String id) async {
    final store = LgThinQStorage();
    final token = await store.token();
    if (token == null || token.isEmpty) {
      throw StateError('LG ThinQ is disconnected.');
    }
    return LgThinQClient(
      personalToken: token,
      country: await store.country(),
      clientId: await store.clientId(),
    ).state(id);
  }

  String _baselineJson(List<FridgeTemperatureReading> readings) =>
      jsonEncode({
        for (final reading in readings)
          reading.identity: {'value': reading.value, 'unit': reading.unit},
      });

  /// Capture a real starting temperature before enabling any alerts.
  Future<void> _seedBaseline(String id) async {
    final readings = fridgeReadings(await _fetchState(id));
    if (readings.isEmpty) {
      throw StateError('LG did not report refrigerator temperatures.');
    }
    await _store.write(
      key: '$_baselinePrefix$id', value: _baselineJson(readings),
    );
    await _store.write(
      key: '$_lastCheckedPrefix$id',
      value: DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<DateTime?> lastChecked(String id) async {
    final raw = await _store.read(key: '$_lastCheckedPrefix$id');
    return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
  }

  /// Check on demand using the same comparison as scheduled background work.
  Future<int> checkDevice(LgThinQDevice device) async {
    if (!(await isEnabled(device.id))) {
      throw StateError('Enable refrigerator notifications first.');
    }
    final state = await _fetchState(device.id);
    final readings = fridgeReadings(state);
    if (readings.isEmpty) {
      throw StateError('LG did not report refrigerator temperatures.');
    }
    await observe(device, state);
    return readings.length;
  }

  /// Verify local-notification permission separately from LG's cloud API.
  Future<void> showTestNotification() async {
    await initialize(allowPermissions: true);
    await _notifications.show(
      id: 19735,
      title: 'TapTether refrigerator alert test',
      body: 'Notifications are configured. iOS background LG checks '
          'are not immediate and may run later.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'taptether_refrigerator', 'Refrigerator temperature changes',
          channelDescription: 'LG refrigerator temperature alerts.',
          importance: Importance.high, priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true, presentSound: true,
        ),
      ),
    );
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final deviceIds = await enabledDevices();
    final previous = await _store.read(key: _alertKey);
    final baselineKey = '$_baselinePrefix$id';
    final checkedKey = '$_lastCheckedPrefix$id';
    final oldBaseline = await _store.read(key: baselineKey);
    final oldChecked = await _store.read(key: checkedKey);
    if (enabled) {
      await initialize(allowPermissions: true);
      await LgThinQStorage().enableBackgroundTokenAccess();
      // No silent first-change loss: fail visibly if LG is unreachable.
      await _seedBaseline(id);
      deviceIds.add(id);
    } else {
      deviceIds.remove(id);
    }
    await _store.write(key: _alertKey,
        value: jsonEncode(deviceIds.toList()));
    try {
      await syncBackgroundTask();
    } catch (_) {
      // Do not show the notification bell enabled if OS scheduling failed.
      if (previous == null) {
        await _store.delete(key: _alertKey);
      } else {
        await _store.write(key: _alertKey, value: previous);
      }
      if (oldBaseline == null) {
        await _store.delete(key: baselineKey);
      } else {
        await _store.write(key: baselineKey, value: oldBaseline);
      }
      if (oldChecked == null) {
        await _store.delete(key: checkedKey);
      } else {
        await _store.write(key: checkedKey, value: oldChecked);
      }
      rethrow;
    }
    if (!enabled) {
      await _store.delete(key: baselineKey);
      await _store.delete(key: checkedKey);
      await _store.delete(key: '$_intervalPrefix$id');
    }
  }

  Future<void> syncBackgroundTask() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final enabled = await enabledDevices();
    if (enabled.isEmpty) {
      await Workmanager().cancelByUniqueName(fridgeBackgroundJob);
      return;
    }
    // WorkManager cannot schedule sub-15-minute background polling.
    // iOS may also defer tasks regardless of the requested frequency.
    final configured = await Future.wait(enabled.map(intervalMinutes));
    await Workmanager().registerPeriodicTask(
      fridgeBackgroundJob,
      fridgeBackgroundJob,
      frequency: Duration(minutes: fridgeBackgroundMinutes(configured)),
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  Future<void> checkAll() async {
    final enabled = await enabledDevices();
    if (enabled.isEmpty) return;
    final store = LgThinQStorage();
    final token = await store.token();
    if (token == null || token.isEmpty) return;
    final devices = await store.enabledDevices();
    final client = LgThinQClient(
      personalToken: token,
      country: await store.country(),
      clientId: await store.clientId(),
    );
    for (final device in devices) {
      if (!enabled.contains(device.id) ||
          !device.type.toUpperCase().contains('REFRIGERATOR')) {
        continue;
      }
      try {
        final state = await client.state(device.id);
        await observe(device, state);
      } catch (_) {
        // Keep previous baseline so outages never generate false changes.
      }
    }
  }

  Future<void> observe(LgThinQDevice device, Object? state) async {
    if (!(await isEnabled(device.id))) return;
    final values = fridgeReadings(state);
    if (values.isEmpty) return;
    final key = '$_baselinePrefix${device.id}';
    final raw = await _store.read(key: key);
    final previous = <String, FridgeTemperatureReading>{};
    if (raw != null) {
      try {
        final entries = jsonDecode(raw);
        if (entries is Map) {
          for (final entry in entries.entries) {
            final v = entry.value;
            if (entry.key is! String || v is! Map) continue;
            final number = v['value'];
            final unit = v['unit'];
            if (number is! num || (unit != 'F' && unit != 'C')) continue;
            final parts = (entry.key as String).split(':');
            if (parts.length != 2) continue;
            previous[entry.key as String] = FridgeTemperatureReading(
              zone: parts[0], kind: parts[1], value: number, unit: unit,
            );
          }
        }
      } catch (_) {
        // A corrupted baseline should be reset, not reported as a change.
      }
    }
    final changes = compareFridgeReadings(previous, values);
    // Write before notifying: an interruption must not replay old changes.
    await _store.write(key: key, value: _baselineJson(values));
    await _store.write(
      key: '$_lastCheckedPrefix${device.id}',
      value: DateTime.now().toUtc().toIso8601String(),
    );
    if (changes.isEmpty) return;
    await initialize();
    for (final change in changes) {
      final after = change.after;
      final zone = after.zone == 'FREEZER' ? 'Freezer' : 'Fridge';
      final title = '${device.name} · $zone ${after.label} changed';
      final body = '${change.before.text} → ${after.text} (LG ThinQ)';
      final id = (device.id.hashCode ^ after.identity.hashCode)
          & 0x7fffffff;
      await _notifications.show(
        id: id, title: title, body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'taptether_refrigerator',
            'Refrigerator temperature changes',
            channelDescription: 'Temperature and setpoint changes detected '
                'during periodic ThinQ checks.',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true, presentSound: true,
          ),
        ),
      );
    }
  }
}
