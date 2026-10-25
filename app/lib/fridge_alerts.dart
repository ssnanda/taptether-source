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

  Future<void> setEnabled(String id, bool enabled) async {
    final deviceIds = await enabledDevices();
    if (enabled) {
      // Ask only when the user explicitly requests notifications.
      await initialize(allowPermissions: true);
      // Explicit consent to perform LG checks after the first unlock on
      // this device. The PAT remains in the non-syncing iOS Keychain.
      await LgThinQStorage().enableBackgroundTokenAccess();
      deviceIds.add(id);
    } else {
      deviceIds.remove(id);
      await _store.delete(key: '$_baselinePrefix$id');
    }
    final previous = await _store.read(key: _alertKey);
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
      rethrow;
    }
  }

  Future<void> syncBackgroundTask() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final enabled = await enabledDevices();
    if (enabled.isEmpty) {
      await Workmanager().cancelByUniqueName(fridgeBackgroundJob);
      return;
    }
    await Workmanager().registerPeriodicTask(
      fridgeBackgroundJob,
      fridgeBackgroundJob,
      frequency: const Duration(minutes: 15),
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
    final saved = <String, Map<String, Object>>{
      for (final item in values)
        item.identity: {'value': item.value, 'unit': item.unit},
    };
    // Write before notifying: an interruption must not replay old changes.
    await _store.write(key: key, value: jsonEncode(saved));
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
