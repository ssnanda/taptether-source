import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'lg_webos_client.dart';
import 'lg_wake_recovery.dart';
import 'tv_network_status.dart';

/// Native iOS shortcuts only store a requested action and a TV identity.
/// All authenticated commands use the existing Flutter secure TV store, and
/// the Flutter app is foregrounded (unlock required) for control intents.
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

  Future<void> select(LgTvDevice tv, {required bool connected}) async {
    if (!Platform.isIOS || tv.clientKey.isEmpty) return;
    try {
      await channel.invokeMethod<bool>('select', {
        'host': tv.host,
        'name': tv.name,
        'connected': connected,
      });
    } on PlatformException {
      // Live Activities may be disabled in system settings.
    } on MissingPluginException {
      // Non-iOS test and generated runners have no native extension.
    }
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
      await select(tv, connected: false);
      if (action == 'open') {
        await onOpenRemote?.call(tv);
        return;
      }
      if (!['power', 'volumeUp', 'volumeDown', 'mute'].contains(action)) {
        return;
      }
      if (action == 'power' && !await lgTvResponds(tv)) {
        await wakeLgTv(tv);
        await LgWakeRecovery.instance.queue(tv);
        onResult?.call('Wake signal sent to ${tv.name}.');
        return;
      }
      final client = LgWebOsClient(tv);
      try {
        await client.connect();
        switch (action) {
          case 'power':
            await client.powerOff();
          case 'volumeUp':
            await client.volumeUp();
          case 'volumeDown':
            await client.volumeDown();
          case 'mute':
            final current = await client.request('ssap://audio/getVolume');
            final muted = current['muted'] == true ||
                current['mute'] == true;
            await client.mute(!muted);
        }
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
