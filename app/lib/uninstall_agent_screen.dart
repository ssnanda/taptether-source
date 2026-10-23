import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import 'computer_store.dart';
import 'discovery.dart';
import 'phone_ssh_keys.dart';
import 'ssh_host_trust.dart';
import 'ssh_provisioner.dart';

/// Removal is only available for a verified online pairing over a separate
/// SSH login. The agent never exposes a remote-uninstall or shell API.
class UninstallAgentScreen extends StatefulWidget {
  const UninstallAgentScreen({
    super.key,
    required this.device,
    required this.verifyDevice,
    required this.onUninstalled,
  });

  final SavedComputer device;
  final Future<bool> Function(SavedComputer) verifyDevice;
  final Future<void> Function(SavedComputer, bool erasePairings) onUninstalled;

  @override
  State<UninstallAgentScreen> createState() => _UninstallAgentScreenState();
}

class _UninstallAgentScreenState extends State<UninstallAgentScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _sudo = TextEditingController();
  final _form = GlobalKey<FormState>();
  SshLoginMethod _login = SshLoginMethod.phoneKey;
  List<SavedSshKey> _keys = [];
  String? _keyId;
  bool _busy = false;
  bool _erase = false;
  String _status = 'Not started';
  String? _error;

  bool get _isMac => widget.device.platform == 'darwin';

  @override
  void initState() {
    super.initState();
    unawaited(_loadKeys());
  }

  Future<void> _loadKeys() async {
    try {
      final storage = PhoneSshKeyStore();
      final keys = await storage.listKeys();
      final chosen = await storage.selectedId();
      if (!mounted) return;
      setState(() {
        _keys = keys;
        _keyId = keys.any((key) => key.id == chosen)
            ? chosen : (keys.isEmpty ? null : keys.first.id);
        if (keys.isEmpty) _login = SshLoginMethod.password;
      });
    } catch (_) {
      if (mounted) setState(() => _login = SshLoginMethod.password);
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _sudo.dispose();
    super.dispose();
  }

  Future<bool> _confirm() async {
    final option = _erase ? 'Uninstall and erase pairing data'
        : 'Uninstall and keep pairing data';
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove agent from ${widget.device.name}?'),
        content: Text('This will stop remote control on '
            '${widget.device.name} and remove its installed agent. '
            '${_erase ? 'Existing phone authorizations and keys will be erased.' : 'Existing computer pairing data will be preserved for reinstall.'} '
            'Your SSH login must be separately authorized.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text(option)),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _uninstall() async {
    if (_busy || _form.currentState?.validate() != true) return;
    if (_login == SshLoginMethod.phoneKey && _keyId == null) {
      setState(() => _error = 'Select an existing phone SSH key.');
      return;
    }
    if (!await _confirm() || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Verifying paired device identity';
    });
    SSHClient? ssh;
    try {
      // An IP can be reused. Refuse destructive SSH actions without
      // authenticating this saved agent's existing TLS-pinned identity.
      if (!isPrivateIPv4(widget.device.host) ||
          !await widget.verifyDevice(widget.device)) {
        throw StateError('The saved agent could not be authenticated at this '
            'LAN address. Refresh My Devices before uninstalling.');
      }
      if (!mounted) return;
      setState(() => _status = 'Authenticating SSH host key');
      final host = widget.device.host;
      final trust = SshHostTrustStore();
      final saved = await trust.trustedFingerprint(host);
      final identities = _login == SshLoginMethod.phoneKey
          ? await PhoneSshKeyStore().authenticationIdentities(id: _keyId)
          : null;
      final socket = await SSHSocket.connect(host, 22)
          .timeout(const Duration(seconds: 8));
      String? observed;
      var changed = false;
      ssh = SSHClient(
        socket,
        username: _username.text.trim(),
        identities: identities,
        onPasswordRequest: _login == SshLoginMethod.password
            ? () => _password.text : null,
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
        onVerifyHostKey: (_, fingerprint) {
          final value = utf8.decode(fingerprint);
          observed = value;
          if (!SshHostTrustStore.validFingerprint(value)) return false;
          if (saved != null && saved != value) {
            changed = true;
            return false;
          }
          return true;
        },
      );
      try {
        await ssh.authenticated.timeout(const Duration(seconds: 20));
      } catch (_) {
        throw StateError(changed
            ? 'SSH host identity changed. Uninstall blocked.'
            : 'SSH authentication failed. Check login or authorized phone key.');
      }
      if (observed == null) {
        throw StateError('SSH host key could not be verified.');
      }
      await trust.rememberAuthenticated(host, observed!);
      if (!mounted) return;
      setState(() => _status = 'Removing installed agent');
      if (_isMac) {
        final suffix = _erase ? '--erase-pairing' : '--keep-pairing';
        final result = await ssh.runWithResult(
            'bash "\$HOME/.local/bin/taptetherctl-mac" uninstall $suffix')
            .timeout(const Duration(seconds: 90));
        if (result.exitCode != 0) {
          throw StateError('Mac agent uninstall failed. Try the Mac tray.');
        }
      } else {
        // Ubuntu requires sudo for systemd/dpkg. Never run a caller-provided
        // shell command, path or URL. Only this fixed packaged uninstaller.
        final session = await ssh.execute(
            _sudo.text.isNotEmpty
                ? 'sudo -S -p "" /bin/bash /usr/share/taptether/4-ubuntu-uninstall.sh --system'
                : 'sudo -n /bin/bash /usr/share/taptether/4-ubuntu-uninstall.sh --system',
            pty: const SSHPtyConfig());
        if (_sudo.text.isNotEmpty) {
          session.stdin.add(Uint8List.fromList(
              utf8.encode('${_sudo.text}\n')));
        }
        await Future.wait([
          session.stdout.drain<void>(),
          session.stderr.drain<void>(),
        ]).timeout(const Duration(minutes: 2));
        final exitCode = await session.waitForExit(
            timeout: const Duration(seconds: 10));
                if (exitCode != 0) {
          throw StateError('Ubuntu system package removal failed. '
              'Run local diagnostics before retrying.');
        }
        final suffix = _erase ? '--complete-erase-pairing'
            : '--complete-keep-pairing';
        final owner = await ssh.runWithResult(
            'bash "\$HOME/.local/bin/taptether-uninstall" $suffix')
            .timeout(const Duration(seconds: 45));
        if (owner.exitCode != 0) {
          throw StateError('System agent removed, but user tray cleanup failed. '
              'Use the local uninstall helper to finish cleanup.');
        }
      }
      if (!mounted) return;
      setState(() => _status = 'Agent removed');
      await widget.onUninstalled(widget.device, _erase);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      // Remote stdout/stderr and credentials are deliberately never displayed.
      setState(() {
        _error = error is StateError ? error.message.toString()
            : 'Uninstall could not complete. Check SSH and device diagnostics.';
      });
    } finally {
      await ssh?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Uninstall Agent')),
        body: ListView(padding: const EdgeInsets.all(18), children: [
          Text(device.name, style: Theme.of(context).textTheme.titleLarge),
          Text('${_isMac ? 'macOS' : 'Ubuntu'} · ${device.host}'),
          const SizedBox(height: 12),
          const Text('Uses your existing paired-device identity to verify '
              'the target, then connects over SSH. SSH must be enabled. '
              'This feature cannot silently uninstall from another computer.'),
          const SizedBox(height: 16),
          Form(key: _form, child: Column(children: [
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(labelText: 'SSH username'),
              autocorrect: false,
              validator: (value) => RegExp(
                  _isMac ? r'^[a-zA-Z_][a-zA-Z0-9_.-]{0,63}$'
                      : r'^[a-z_][a-z0-9_-]{0,30}$')
                  .hasMatch(value?.trim() ?? '') ? null : 'Invalid SSH username',
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SshLoginMethod>(
              initialValue: _login,
              decoration: const InputDecoration(labelText: 'SSH authentication'),
              items: [
                if (_keys.isNotEmpty) const DropdownMenuItem(
                    value: SshLoginMethod.phoneKey,
                    child: Text('Saved phone SSH key')),
                const DropdownMenuItem(
                    value: SshLoginMethod.password, child: Text('SSH password')),
              ],
              onChanged: (value) => setState(() => _login = value!),
            ),
            if (_login == SshLoginMethod.phoneKey) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _keyId,
                decoration: const InputDecoration(labelText: 'Phone SSH key'),
                items: _keys.map((key) => DropdownMenuItem(
                    value: key.id, child: Text(key.name))).toList(),
                onChanged: (value) => setState(() => _keyId = value),
              ),
            ] else ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _password, obscureText: true,
                decoration: const InputDecoration(labelText: 'SSH password'),
                validator: (value) => (value ?? '').isEmpty
                    ? 'SSH password required' : null,
              ),
            ],
            if (!_isMac) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _sudo, obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Ubuntu sudo password (if required)'),
              ),
            ],
          ])),
          const SizedBox(height: 14),
          SwitchListTile.adaptive(
            value: _erase,
            title: const Text('Erase saved pairing on this computer'),
            subtitle: const Text('Off keeps pairing for future reinstall. '
                'On erases local authorized phones, certificates and settings.'),
            onChanged: _busy ? null : (value) => setState(() => _erase = value),
          ),
          if (_busy) const LinearProgressIndicator(),
          Text('Status: $_status'),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: TextStyle(
              color: Theme.of(context).colorScheme.error)),
          ),
          const SizedBox(height: 15),
          FilledButton.icon(
            key: const ValueKey('confirm-remote-uninstall'),
            onPressed: _busy ? null : _uninstall,
            icon: const Icon(Icons.delete_forever_outlined),
            label: Text(_busy ? 'Uninstalling…' : 'Uninstall from computer'),
          ),
        ]),
      ),
    );
  }
}
