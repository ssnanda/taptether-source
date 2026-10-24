import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'computer_store.dart';
import 'discovery.dart';
import 'phone_ssh_keys.dart';
import 'ssh_host_trust.dart';
import 'ssh_provisioner.dart';
import 'ubuntu_uninstall_recovery.dart';

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
  String _failureStage = 'Not started';
  bool _offlineRecovery = false;

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
      _failureStage = 'Checking the saved device';
      _offlineRecovery = false;
      _status = 'Verifying paired device identity';
    });
    SSHClient? ssh;
    try {
      // Recover broken/offline Ubuntu services only with a PREVIOUSLY PINNED
      // SSH host key. Never replace a failed TLS agent identity check with
      // trust-on-first-use SSH, since an IP may be reassigned.
      if (!isPrivateIPv4(widget.device.host)) {
        throw StateError('Uninstall requires the device’s saved private IP.');
      }
      final host = widget.device.host;
      final trust = SshHostTrustStore();
      final saved = await trust.trustedFingerprint(host);
      bool agentVerified = false;
      try {
        agentVerified = await widget.verifyDevice(widget.device)
            .timeout(const Duration(seconds: 7));
      } catch (_) {
        // Offline or partially installed agent; SSH recovery can still be safe
        // if this phone already remembers this exact SSH server identity.
      }
      if ((_isMac && !agentVerified) ||
          (!_isMac && !canStartOfflineUbuntuUninstall(
            agentVerified: agentVerified,
            previouslyTrustedSshFingerprint: saved))) {
        throw StateError('Agent is unreachable and this phone does not have '
            'a previously trusted SSH host key for this IP. '
            'Uninstall blocked to avoid removing another computer.');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _offlineRecovery = !agentVerified;
        _failureStage = 'Verifying saved SSH host key';
        _status = agentVerified
            ? 'Authenticating SSH host key'
            : 'Agent offline — checking previously trusted SSH identity';
      });
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
      // Host changed while the agent was unavailable? Never trust it.
      if (!agentVerified && saved != observed) {
        throw StateError('Offline recovery blocked: trusted SSH host '
            'fingerprint does not match this computer.');
      }
      await trust.rememberAuthenticated(host, observed!);
      if (!mounted) {
        return;
      }
      setState(() {
        _failureStage = 'Removing system package';
        _status = _offlineRecovery
            ? 'Trusted SSH host confirmed. Removing broken Ubuntu agent'
            : 'Removing installed agent';
      });
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
        // Capture only bounded bytes for fixed diagnostic markers. Never
        // expose stdout, stderr, passwords, paths or package log contents.
        final bounded = <int>[];
        Future<void> collect(Stream<Uint8List> source) async {
          await for (final chunk in source) {
            if (bounded.length < 16384) {
              bounded.addAll(chunk.take(16384 - bounded.length));
            }
          }
        }
        await Future.wait([
          collect(session.stdout),
          collect(session.stderr),
        ]).timeout(const Duration(minutes: 2));
        final exitCode = await session.waitForExit(
            timeout: const Duration(seconds: 10));
        if (exitCode != 0) {
          final text = utf8.decode(bounded, allowMalformed: true);
          final code = ubuntuUninstallFailureStage(text);
          _failureStage = code;
          throw StateError('[UNINSTALL:$code] Ubuntu service/package '
              'removal failed. Verify sudo access and package health.');
        }
        if (mounted) {
          setState(() {
            _failureStage = 'Cleaning up user files';
            _status = 'System package removed; cleaning up user tray';
          });
        }
        final suffix = _erase ? '--complete-erase-pairing'
            : '--complete-keep-pairing';
        final owner = await ssh.runWithResult(
            'bash "\$HOME/.local/bin/taptether-uninstall" $suffix')
            .timeout(const Duration(seconds: 45));
        if (owner.exitCode != 0) {
          throw StateError('[UNINSTALL:user-cleanup] System agent removed, '
              'but desktop tray cleanup failed. '
              'Check ~/.local/bin/taptether-uninstall on Ubuntu.');
        }
      }
      if (!mounted) return;
      setState(() {
        _status = 'Agent removed successfully';
        _failureStage = 'Complete';
      });
      await widget.onUninstalled(widget.device, _erase);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      // Remote stdout/stderr and credentials are deliberately never displayed.
      setState(() {
        _error = error is StateError ? error.message.toString()
            : 'Uninstall could not complete at $_failureStage. '
              'Check SSH and sudo access.';
        _status = 'Uninstall stopped';
      });
    } finally {
      await ssh?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  String _safeDiagnostics() => [
    'TapTether remote agent uninstall diagnostics',
    'Platform: ${_isMac ? "macOS" : "Ubuntu"}',
    'Device IP: ${widget.device.host}',
    'SSH method: ${_login == SshLoginMethod.phoneKey ? "saved phone key" : "SSH password"}',
    'Sudo password entered: ${_sudo.text.isNotEmpty ? "yes" : "no"}',
    'Offline agent recovery: ${_offlineRecovery ? "yes, pinned SSH identity" : "no"}',
    'Last stage: $_failureStage',
    'Status: $_status',
    'Result: ${_error ?? "No error reported"}',
    'Credentials, raw remote output, and pairing data excluded.',
  ].join('\n');

  Future<void> _copyDiagnostics() async {
    await Clipboard.setData(ClipboardData(text: _safeDiagnostics()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Safe uninstall diagnostics copied')));
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
          if (_offlineRecovery)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Agent service was unavailable. '
                  'Removal proceeds only because this phone previously '
                  'trusted the exact SSH server key at this IP.'),
            ),
          OutlinedButton.icon(
            key: const ValueKey('copy-uninstall-diagnostics'),
            onPressed: _copyDiagnostics,
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Copy safe diagnostics'),
          ),
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
