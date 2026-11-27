import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:workmanager/workmanager.dart';

import 'sideloader_api.dart';

/// iOS BGAppRefresh identifier; staged in Info.plist by
/// bin/2h-tt-fridge-background.sh. iOS decides when it actually runs.
const sideLoaderBackgroundJob = 'com.taptether.taptether.sideloader-refresh';
const _notifiedKey = 'taptether.sideloader.notified.v1';
const _lastCheckKey = 'taptether.sideloader.background.result.v1';

/// Background "phone is here" check: signs in with the saved SideLoader
/// login, asks the server to renew due apps and install source updates, and
/// alerts only when a renewal or update failed or signing is paused.
class SideLoaderBackground {
  SideLoaderBackground._();
  static final SideLoaderBackground instance = SideLoaderBackground._();
  static const _store = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  final _notifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Register (or cancel) the periodic task to match the saved login.
  Future<void> schedule() async {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    final api = SideLoaderApi();
    try {
      if (await api.savedCredentials() == null) {
        await Workmanager().cancelByUniqueName(sideLoaderBackgroundJob);
        return;
      }
      await Workmanager().registerPeriodicTask(
        sideLoaderBackgroundJob,
        sideLoaderBackgroundJob,
        frequency: const Duration(hours: 1),
        constraints: Constraints(networkType: NetworkType.connected),
      );
    } finally {
      api.close();
    }
  }

  Future<void> cancel() async {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    await Workmanager().cancelByUniqueName(sideLoaderBackgroundJob);
  }

  /// Ask for alert permission while the app is in the foreground.
  Future<void> requestPermission() async {
    await _init();
    if (Platform.isIOS) {
      await _notifications.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: false, sound: true);
    } else if (Platform.isAndroid) {
      await _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }
  }

  /// Background entry point. Returns false only on an unexpected error.
  Future<bool> run() async {
    final api = SideLoaderApi();
    try {
      final saved = await api.savedCredentials();
      if (saved == null) return true;
      await api.login(saved.url, saved.user, saved.password);
      final state = await api.state();
      var device = await api.savedDevice() ?? '';
      if (!state.devices.any((d) => d.udid == device)) {
        device = state.devices.isEmpty ? '' : state.devices.first.udid;
      }
      final status = await api.autoRun(device);
      await reportFailures(status, state);
      await _store.write(key: _lastCheckKey,
          value: '${DateTime.now().toIso8601String()} ok');
      return true;
    } on SideLoaderException catch (e) {
      // Off the Mac's network is normal; never alert for "unreachable".
      await _store.write(key: _lastCheckKey,
          value: '${DateTime.now().toIso8601String()} $e');
      return true;
    } catch (e) {
      await _store.write(key: _lastCheckKey,
          value: '${DateTime.now().toIso8601String()} error');
      return false;
    } finally {
      api.close();
    }
  }

  /// Notify once per failure: a failed last run, failed updates, or a
  /// signing pause after a failed Apple attempt.
  Future<void> reportFailures(
      SideLoaderAutoStatus status, SideLoaderState state) async {
    String? title, body, key;
    if (state.blocked) {
      title = 'SideLoader signing is paused';
      body = state.blockedReason.isEmpty
          ? 'A signing attempt failed. Open SideLoader to review and resume.'
          : state.blockedReason;
      key = 'blocked:${state.blockedReason}';
    } else if (status.lastRunFailed) {
      final failed = status.failedUpdates;
      title = failed.isNotEmpty
          ? 'SideLoader update failed' : 'SideLoader renewal failed';
      body = failed.isNotEmpty ? failed.join('\n') : status.lastMessage;
      key = 'run:${status.lastRun}';
    }
    if (key == null) {
      await _store.delete(key: _notifiedKey);
      return;
    }
    if (await _store.read(key: _notifiedKey) == key) return;
    await _init();
    await _notifications.show(
      id: 0x51de10ad,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'taptether_sideloader', 'SideLoader renewals',
          channelDescription: 'Failed automatic app renewals or updates.',
          importance: Importance.high, priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true, presentBanner: true,
          presentList: true, presentSound: true,
        ),
      ),
    );
    await _store.write(key: _notifiedKey, value: key);
  }

  Future<void> _init() async {
    if (_initialized) return;
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
}
