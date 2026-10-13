import 'dart:async';

import 'package:flutter/material.dart';

import 'discovery.dart';
import 'phone_ssh_keys.dart';
import 'ssh_provisioner.dart';

/// Full-screen, keyboard-safe SSH installer. Never prints SSH passwords,
/// pairing tokens, private keys, or remote installer logs.
class UbuntuInstallScreen extends StatefulWidget {
  const UbuntuInstallScreen({
    super.key,
    required this.initialHost,
    required this.onInstalled,
  });

  final String initialHost;
  final Future<bool> Function(InstalledAgent installed) onInstalled;

  @override
  State<UbuntuInstallScreen> createState() => _UbuntuInstallScreenState();
}

class _UbuntuInstallScreenState extends State<UbuntuInstallScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _host = TextEditingController(text: widget.initialHost);
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _sudoPassword = TextEditingController();
  List<SavedSshKey> _keys = [];
  String? _keyId;
  SshLoginMethod _login = SshLoginMethod.password;
  bool _authorizeKey = false;
  bool _busy = false;
  bool _success = false;
  String? _error;
  String _stage = '';
  InstalledAgent? _installed;

  @override
  void initState() {
    super.initState();
    unawaited(_loadKeys());
  }

  Future<void> _loadKeys() async {
    try {
      final store = PhoneSshKeyStore();
      final keys = await store.listKeys();
      final selected = await store.selectedId();
      if (mounted) {
        setState(() {
          _keys = keys;
          _keyId = keys.any((k) => k.id == selected)
              ? selected : (keys.isEmpty ? null : keys.first.id);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'SSH keys could not be loaded. '
            'Password login is still available.');
      }
    }
  }

  @override
  void dispose() {
    _host.dispose();
    _username.dispose();
    _password.dispose();
    _sudoPassword.dispose();
    super.dispose();
  }

  String? _validateHost(String? value) =>
      isPrivateIPv4((value ?? '').trim())
          ? null : 'Enter a private LAN IPv4 address.';

  String? _validateUsername(String? value) =>
      RegExp(r'^[a-z_][a-z0-9_-]{0,30}$').hasMatch((value ?? '').trim())
          ? null : 'Enter a valid Ubuntu username.';

  void _report(String stage) {
    if (mounted) setState(() => _stage = stage);
  }

  Future<void> _pairInstalled() async {
    final installed = _installed;
    if (installed == null) return;
    _report('Pairing phone, verifying connection and saving device');
    try {
      final paired = await widget.onInstalled(installed);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _success = paired;
        _error = paired ? null
            : 'Ubuntu installation completed, but TapTether could not '
              'verify and save the phone pairing. You can retry pairing.';
        _stage = paired ? 'Installed and paired successfully'
            : 'Installed, but not paired';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Ubuntu installation completed, but pairing failed. '
            'Check the device connection and retry pairing.';
        _stage = 'Installed, but not paired';
      });
    }
  }

  Future<void> _install() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    if (_login == SshLoginMethod.phoneKey && _keyId == null) {
      setState(() => _error = 'Choose an SSH key before installing.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _success = false;
      _error = null;
      _installed = null;
      _stage = 'Preparing secure local connection';
    });
    final request = SshInstallRequest(
      host: _host.text.trim(),
      username: _username.text.trim(),
      sshPassword: _login == SshLoginMethod.password ? _password.text : '',
      sudoPassword: _sudoPassword.text,
      loginMethod: _login,
      sshKeyId: _keyId,
      authorizePhoneKey: _login == SshLoginMethod.password && _authorizeKey,
    );
    try {
      _installed = await UbuntuSshProvisioner.install(request,
          onProgress: _report);
      if (!mounted) return;
      await _pairInstalled();
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message;
          _stage = 'Could not start installation';
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // Never include SSH command output or credentials in a status view.
        _error = error is StateError ? error.message.toString() :
            'SSH installation failed at: $_stage. '
            'Check your SSH login, network connection and sudo permissions.';
        _stage = 'Installation failed';
      });
    }
  }

  Future<void> _retryPairing() async {
    if (_busy || _installed == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    await _pairInstalled();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final finished = _success || _installed != null;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Install Ubuntu agent')),
        body: SafeArea(child: Column(children: [
          Expanded(child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              if (!_busy && !finished) ...[
                Text('Computer connection',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text('Install and pair a computer over your local network. '
                    'You do not need to visit the computer to retrieve a fingerprint.',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 18),
                Form(key: _formKey, child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _host,
                      decoration: const InputDecoration(
                          labelText: 'Ubuntu IP address',
                          hintText: '192.168.1.100'),
                      keyboardType: TextInputType.number,
                      autocorrect: false,
                      validator: _validateHost,
                    ),
                    const SizedBox(height: 18),
                    TextFormField(
                      controller: _username,
                      decoration: const InputDecoration(
                          labelText: 'SSH username'),
                      autocorrect: false,
                      validator: _validateUsername,
                    ),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<SshLoginMethod>(
                      initialValue: _login,
                      decoration: const InputDecoration(
                          labelText: 'SSH login method'),
                      items: [
                        const DropdownMenuItem(
                          value: SshLoginMethod.password,
                          child: Text('SSH password')),
                        DropdownMenuItem(
                          value: SshLoginMethod.phoneKey,
                          enabled: _keys.isNotEmpty,
                          child: const Text('Saved SSH key')),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _login = value);
                      },
                    ),
                    const SizedBox(height: 18),
                    if (_login == SshLoginMethod.password) ...[
                      TextFormField(
                        controller: _password,
                        decoration: const InputDecoration(
                            labelText: 'SSH password'),
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        validator: (value) => (value ?? '').isEmpty
                            ? 'Enter the SSH password.' : null,
                      ),
                      const SizedBox(height: 14),
                      if (_keys.isNotEmpty)
                        CheckboxListTile(
                          value: _authorizeKey,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Authorize this phone SSH key'),
                          subtitle: const Text(
                            'Add the selected public key for future key logins.'),
                          onChanged: (value) =>
                              setState(() => _authorizeKey = value ?? false),
                        ),
                    ] else if (_keys.isNotEmpty) ...[
                      DropdownButtonFormField<String>(
                        initialValue: _keyId,
                        decoration: const InputDecoration(
                            labelText: 'SSH key'),
                        items: [
                          for (final key in _keys)
                            DropdownMenuItem(
                              value: key.id, child: Text(key.name)),
                        ],
                        onChanged: (id) => setState(() => _keyId = id),
                        validator: (id) =>
                            id == null ? 'Choose an SSH key.' : null,
                      ),
                      const SizedBox(height: 14),
                    ],
                    const Divider(height: 30),
                    Text('Ubuntu administrator access',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _sudoPassword,
                      decoration: const InputDecoration(
                        labelText: 'Sudo password (optional)',
                        helperText: 'Leave blank if sudo is passwordless.'),
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                    ),
                    const SizedBox(height: 18),
                    Text('On first connection, TapTether remembers the '
                        'SSH server identity after successful login. If it '
                        'changes later, connection is blocked. A first '
                        'connection is not independently verified.',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                )),
              ] else ...[
                const SizedBox(height: 22),
                Center(child: Icon(
                  _success ? Icons.check_circle_outline :
                    _installed != null ? Icons.warning_amber_rounded :
                    _busy ? Icons.cloud_upload_outlined : Icons.error_outline,
                  color: _success ? scheme.primary : scheme.onSurface,
                  size: 64,
                )),
                const SizedBox(height: 20),
                Text(_stage,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge),
                if (_busy) ...[
                  const SizedBox(height: 24),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  const Text('Keep TapTether open while this step completes.',
                      textAlign: TextAlign.center),
                ],
              ],
              if (_error != null) ...[
                const SizedBox(height: 22),
                Card(child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Attention',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Text(_error!),
                    ],
                  ),
                )),
              ],
            ],
          )),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
            child: SizedBox(width: double.infinity, child:
              _busy
                ? const OutlinedButton(onPressed: null,
                    child: Text('Installation in progress'))
                : _success
                  ? FilledButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.desktop_windows_outlined),
                      label: const Text('Open remote'),
                    )
                  : _installed != null
                    ? FilledButton.icon(
                        onPressed: _retryPairing,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry pairing'),
                      )
                    : FilledButton.icon(
                        onPressed: _install,
                        icon: const Icon(Icons.install_desktop),
                        label: const Text('Install & pair'),
                      ),
            ),
          ),
        ])),
      ),
    );
  }
}
