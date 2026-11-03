import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'lg_webos_client.dart';
import 'lg_connection_timing.dart';
import 'lg_wake_recovery.dart';
import 'tv_network_status.dart';

/// iOS Live Activity and Control Center actions execute native authenticated
/// SSAP requests without foregrounding Flutter. The selected TV identity is
/// shared with the widget; its client key is copied only into Runner Keychain.
/// The old pending-action handler remains for migration from older builds.
class TvQuickControls {
  TvQuickControls._();
  static final instance = TvQuickControls._();
  static const channel = MethodChannel('taptether/tv-controls');

  Future<void> Function(LgTvDevice tv)? onOpenRemote;
  void Function(String message)? onResult;
  bool _working = false;

  void initialize() {
    if (!Platform.isIOS) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'pendingControl') unawaited(consumePending());
    });
  }

  /// A connected socket alone is not proof the TV panel is powered on.
  /// If power status is unavailable, suppress the Live Activity.
  static bool confirmedPowerOn(Map<String, dynamic> reply) {
    final state = reply['state']?.toString().toLowerCase().trim();
    return state == 'active' || state == 'screen saver';
  }

  static Future<bool> readPowerOn(LgWebOsClient client) async {
    try {
      final reply = await client.request(
        'ssap://com.webos.service.tvpower/power/getPowerState',
      ).timeout(const Duration(seconds: 3));
      return confirmedPowerOn(reply);
    } catch (_) {
      return false;
    }
  }

  Future<void> select(LgTvDevice tv, {
    required bool connected,
    bool tvPowerOn = false,
  }) async {
    if (!Platform.isIOS || tv.clientKey.isEmpty) return;
    try {
      await channel.invokeMethod<bool>('select', {
        'host': tv.host,
        'name': tv.name,
        'tlsPin': tv.tlsPin,
        'clientKey': tv.clientKey,
        'macAddress': tv.macAddress,
        'connected': connected && tvPowerOn,
        'tvPowerOn': tvPowerOn,
      });
    } on PlatformException {
      // Live Activities may be disabled in system settings.
    } on MissingPluginException {
      // Non-iOS test and generated runners have no native extension.
    }
  }

  /// The widget reads the layout from the shared app-group and an Activity
  /// content update renders the new layout without opening the TV remote.
  Future<String> getLockScreenLayout() async {
    if (!Platform.isIOS) return 'compact';
    final stored = await channel.invokeMethod<String>('getLayout');
    return stored == 'wide' ? 'wide' : 'compact';
  }

  Future<void> setLockScreenLayout(String layout) async {
    if (layout != 'compact' && layout != 'wide') {
      throw ArgumentError.value(layout, 'layout', 'Use compact or wide');
    }
    if (!Platform.isIOS) return;
    await channel.invokeMethod<bool>('setLayout', layout);
  }

  Future<void> consumePending() async {
    if (!Platform.isIOS || _working) return;
    _working = true;
    try {
      final request = await channel.invokeMapMethod<String, dynamic>('consume');
      if (request == null) return;
      final action = request['action'] as String?;
      final host = request['host'] as String?;
      if (action == null || host == null) return;
      final saved = await LgTvStore().read();
      final matches = saved.where((tv) => tv.host == host).toList();
      if (matches.isEmpty) {
        onResult?.call('Selected TV no longer saved. Choose a TV in Devices.');
        return;
      }
      final tv = matches.first;
      if (action == 'open') {
        await onOpenRemote?.call(tv);
        return;
      }
      if (!['power', 'volumeUp', 'volumeDown', 'mute'].contains(action)) {
        return;
      }
      if (action == 'power' && !await lgTvResponds(tv)) {
        await wakeLgTv(tv);
        // Record the actual wake packet before starting background recovery.
        try {
          await LgConnectionTimingStore().powerOn(tv, DateTime.now());
        } catch (_) {}
        await LgWakeRecovery.instance.queue(tv);
        await select(tv, connected: false);
        onResult?.call('Wake signal sent to ${tv.name}.');
        return;
      }
      final client = LgWebOsClient(tv);
      try {
        await client.connect();
        try {
          final now = DateTime.now();
          final timings = LgConnectionTimingStore();
          await timings.found(tv, now);
          await timings.connected(tv, now);
        } catch (_) {}
        switch (action) {
          case 'power':
            await client.powerOff();
            break;
          case 'volumeUp':
            await client.volumeUp();
            break;
          case 'volumeDown':
            await client.volumeDown();
            break;
          case 'mute':
            final current = await client.request('ssap://audio/getVolume');
            final muted = current['muted'] == true ||
                current['mute'] == true;
            await client.mute(!muted);
            break;
        }
        final tvOn = action == 'power' ? false : await readPowerOn(client);
        await select(tv, connected: tvOn, tvPowerOn: tvOn);
        onResult?.call('TV control sent to ${tv.name}.');
      } finally {
        await client.disconnect();
      }
    } on PlatformException {
      onResult?.call('Unable to open the selected TV control.');
    } on MissingPluginException {
      // Widget controls are only supported on native iOS.
    } catch (_) {
      onResult?.call('TV unavailable. Open the remote to reconnect.');
    } finally {
      _working = false;
    }
  }
}
