import 'dart:async';

import 'package:flutter/material.dart';

import 'xbox_lan_session.dart';
import 'xbox_smartglass.dart';

/// Real LAN controls only. No browser view and no synthetic web gamepad.
/// The controls become enabled only after a verified encrypted handshake
/// and successful opening of the Xbox input channel.
class XboxRemoteSessionScreen extends StatefulWidget {
  const XboxRemoteSessionScreen({
    super.key,
    required this.host,
    this.name = 'Xbox',
    this.openOfficialAtStart = false,
    this.onManage,
    this.known,
    this.onConnected,
  });

  final String host;
  final String name;
  final bool openOfficialAtStart; // compatibility; no browser is opened
  final VoidCallback? onManage;
  final XboxConsole? known;
  final Future<void> Function(XboxConsole)? onConnected;

  @override
  State<XboxRemoteSessionScreen> createState() =>
      _XboxRemoteSessionScreenState();
}

class _XboxRemoteSessionScreenState extends State<XboxRemoteSessionScreen>
    with WidgetsBindingObserver {
  XboxLanSession? _session;
  String _status = 'Connecting over local Wi-Fi…';
  String? _error;
  String? _saveWarning;
  bool _connecting = true;
  int _held = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (!mounted) return;
    await _session?.close();
    _session = null;
    setState(() {
      _status = 'Connecting over local Wi-Fi…';
      _error = null;
      _saveWarning = null;
      _connecting = true;
      _held = 0;
    });
    try {
      final connected = await XboxLanSession.connect(
          widget.host, known: widget.known);
      if (!mounted) {
        await connected.close();
        return;
      }
      _session = connected;
      setState(() {
        _connecting = false;
        _status = 'Connected · ${connected.discovered?.name ?? widget.host}';
      });
      if (connected.discovered != null) {
        try {
          await widget.onConnected?.call(connected.discovered!);
        } catch (_) {
          if (mounted) {
            setState(() => _saveWarning =
                'Xbox connected, but the saved device could not be updated.');
          }
        }
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _status = 'Not connected';
        _error = error is XboxLanException ? error.message :
            'Could not establish a local Xbox connection.';
      });
    }
  }

  void _button(int mask, bool down) {
    final session = _session;
    if (session == null || !session.connected) return;
    final next = down ? (_held | mask) : (_held & ~mask);
    if (_held == next) return;
    _held = next;
    try {
      session.buttons(_held);
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = 'Disconnected';
          _error = 'The local controller stopped responding.';
        });
      }
    }
  }

  void _releaseAll() {
    _held = 0;
    try {
      if (_session?.connected == true) {
        _session!.buttons(0);
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _releaseAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _releaseAll();
    unawaited(_session?.close());
    super.dispose();
  }

  Widget _key(String label, int mask, Color color, {double width = 58}) {
    final active = _session?.connected == true && !_connecting &&
        _error == null;
    return Semantics(
      button: true,
      enabled: active,
      label: 'Xbox $label',
      child: Listener(
        onPointerDown: active ? (_) => _button(mask, true) : null,
        onPointerUp: active ? (_) => _button(mask, false) : null,
        onPointerCancel: active ? (_) => _button(mask, false) : null,
        child: Container(
          height: 51,
          width: width,
          margin: const EdgeInsets.all(4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? color : Theme.of(context).disabledColor
                .withValues(alpha: .18),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(label, style: TextStyle(
            color: active ? Colors.white :
                Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            fontSize: 17,
          )),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Xbox · Wi-Fi remote'), actions: [
        if (widget.onManage != null)
          IconButton(
            key: const ValueKey('xbox-remote-settings'),
            tooltip: 'Xbox settings',
            onPressed: widget.onManage,
            icon: const Icon(Icons.tune_rounded),
          ),
        IconButton(
          tooltip: 'Reconnect Xbox',
          onPressed: _connecting ? null : _connect,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ]),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        children: [
          Row(children: [
            Icon(_session?.connected == true && _error == null
                ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                color: _session?.connected == true && _error == null
                    ? Colors.green : scheme.error),
            const SizedBox(width: 9),
            Expanded(child: Text(_status,
                style: Theme.of(context).textTheme.titleMedium)),
          ]),
          if (_connecting) const LinearProgressIndicator(),
          if (_error != null) Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!,
              style: TextStyle(color: scheme.error)),
          ),
          if (_saveWarning != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_saveWarning!,
                style: TextStyle(color: scheme.error)),
            ),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _key('LB', XboxLanButton.lb, scheme.primary, width: 85),
            _key('RB', XboxLanButton.rb, scheme.primary, width: 85),
          ]),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            Column(children: [
              _key('↑', XboxLanButton.up, scheme.primary, width: 72),
              Row(mainAxisSize: MainAxisSize.min, children: [
                _key('←', XboxLanButton.left, scheme.primary, width: 58),
                const SizedBox(width: 9),
                _key('→', XboxLanButton.right, scheme.primary, width: 58),
              ]),
              _key('↓', XboxLanButton.down, scheme.primary, width: 72),
            ]),
            Column(children: [
              _key('Y', XboxLanButton.y, Colors.amber.shade800),
              Row(mainAxisSize: MainAxisSize.min, children: [
                _key('X', XboxLanButton.x, Colors.blue.shade700),
                _key('B', XboxLanButton.b, Colors.red.shade700),
              ]),
              _key('A', XboxLanButton.a, Colors.green.shade700),
            ]),
          ]),
          const SizedBox(height: 18),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _key('View', XboxLanButton.view, scheme.primary, width: 82),
            _key('Xbox', XboxLanButton.xbox, scheme.primary, width: 82),
            _key('Menu', XboxLanButton.menu, scheme.primary, width: 82),
          ]),
          const SizedBox(height: 16),
          Text(widget.host, textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        ],
      )),
    );
  }
}
