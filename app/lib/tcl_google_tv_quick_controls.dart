import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'tcl_google_tv_protocol/key_codes.dart';
import 'tcl_google_tv_protocol/remote_client.dart';
import 'tcl_google_tv_store.dart';

/// Compact, in-app TCL control sheet. This is not the iOS Lock Screen native
/// widget; native background actions require a separate paired TLS executor.
class TclGoogleTvQuickControls extends StatefulWidget {
  const TclGoogleTvQuickControls({super.key, required this.tv});
  final TclGoogleTv tv;

  @override
  State<TclGoogleTvQuickControls> createState() =>
      _TclGoogleTvQuickControlsState();
}

class _TclGoogleTvQuickControlsState extends State<TclGoogleTvQuickControls> {
  RemoteClient? _client;
  bool _connected = false;
  String _status = 'Connecting to TV…';

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  Future<void> _connect() async {
    final tv = widget.tv;
    if (!tv.paired) {
      if (mounted) setState(() => _status = 'Pair the TV in Devices first.');
      return;
    }
    try {
      final ctx = SecurityContext(withTrustedRoots: false);
      ctx.useCertificateChainBytes(utf8.encode(tv.certificatePem));
      ctx.usePrivateKeyBytes(utf8.encode(tv.privateKeyPem));
      final client = RemoteClient(host: tv.host, context: ctx,
          expectedFingerprint: tv.serverFingerprint);
      _client = client;
      await client.connect();
      if (!mounted) {
        client.dispose();
        return;
      }
      setState(() {
        _connected = true;
        _status = 'Connected';
      });
    } catch (_) {
      if (mounted) {
        setState(() => _status =
            'TV is unavailable. Reconnect from the saved TV remote.');
      }
    }
  }

  void _command(int code) {
    if (!_connected || _client == null) return;
    try {
      _client!.sendKey(code);
    } catch (_) {
      if (mounted) {
        setState(() => _status = 'Command could not be sent.');
      }
    }
  }

  Widget _button(String label, IconData icon, int key) =>
      OutlinedButton.icon(
        onPressed: _connected ? () => _command(key) : null,
        icon: Icon(icon, size: 20),
        label: Text(label),
      );

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Icon(Icons.tv_rounded),
          const SizedBox(width: 9),
          Expanded(child: Text(widget.tv.name,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium)),
          IconButton(
            tooltip: 'Close quick controls',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ]),
        const SizedBox(height: 4),
        Text(_status, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        Wrap(spacing: 9, runSpacing: 8,
          alignment: WrapAlignment.center, children: [
          _button('Power', Icons.power_settings_new, KeyCode.power),
          _button('Mute', Icons.volume_off, KeyCode.volumeMute),
          _button('Vol −', Icons.volume_down, KeyCode.volumeDown),
          _button('Vol +', Icons.volume_up, KeyCode.volumeUp),
          _button('Home', Icons.home, KeyCode.home),
          _button('Back', Icons.arrow_back, KeyCode.back),
          _button('Play/Pause', Icons.play_arrow, KeyCode.mediaPlayPause),
        ]),
      ]),
    ),
  );

  @override
  void dispose() {
    _client?.dispose();
    super.dispose();
  }
}
