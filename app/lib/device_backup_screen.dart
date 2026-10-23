import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_security.dart';
import 'automatic_device_backup.dart';
import 'device_backup.dart';

class DeviceBackupScreen extends StatefulWidget {
  const DeviceBackupScreen({super.key, this.onRestored});
  final Future<void> Function()? onRestored;
  @override
  State<DeviceBackupScreen> createState() => _DeviceBackupScreenState();
}

class _DeviceBackupScreenState extends State<DeviceBackupScreen> {
  static const _passwordKey = 'taptether.backup.saved-password.v1';
  static const _noPasswordKey = 'taptether.backup.unprotected.v1';
  static const _lastManualKey = 'taptether.backup.last-manual-location.v1';
  final _secure = const FlutterSecureStorage();
  final _store = DeviceBackupStore();
  final _auto = AutomaticDeviceBackup.instance;
  bool _busy = false;
  String? _error;
  int? _entries;
  Map<String, String> _records = {};
  String? _rememberedPassword;
  String? _lastManualLocation;
  bool _usePassword = true;

  void _automaticChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _auto.addListener(_automaticChanged);
    _refresh();
    _auto.initialize();
    _loadBackupOptions();
  }

  Future<void> _loadBackupOptions() async {
    try {
      final password = await _secure.read(key: _passwordKey);
      final noPassword = await _secure.read(key: _noPasswordKey);
      final lastLocation = await _secure.read(key: _lastManualKey);
      if (mounted) {
        setState(() {
          _rememberedPassword = password;
          _usePassword = noPassword != 'true';
          _lastManualLocation = lastLocation;
        });
      }
    } catch (_) {
      // Secure storage availability is reported by the backup operation.
    }
  }

  Future<void> _refresh() async {
    try {
      final data = await _store.snapshot();
      if (mounted) {
        setState(() {
          _entries = data.length;
          _records = data;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Secure storage unavailable. Restore will work when '
            'device storage becomes available.');
      }
    }
  }

  void _showContents() {
    String label(String key) {
      if (key == 'taptether.trusted.computers.v1') {
        return 'Paired computers';
      }
      if (key == 'taptether.lg.webos.pairings.v1') return 'LG TVs';
      if (key == 'taptether.samsung.tv.pairings.v1') {
        return 'Samsung TVs';
      }
      if (key == 'taptether.device.ed25519.v1') {
        return 'Phone identity';
      }
      if (key.startsWith('taptether.ssh.')) {
        return 'SSH keys and trusted hosts';
      }
      if (key == 'taptether.network.locations.v1') {
        return 'Network labels';
      }
      if (key.startsWith('taptether.remote.layout.v1.')) {
        return 'Remote preferences';
      }
      return 'Appearance and settings';
    }
    final categories = <String, int>{};
    for (final key in _records.keys) {
      final category = label(key);
      categories[category] = (categories[category] ?? 0) + 1;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('What is backed up?',
              style: Theme.of(sheet).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('Records are saved settings, not individual devices.'),
          for (final item in categories.entries)
            ListTile(dense: true, title: Text(item.key),
                trailing: Text('${item.value}')),
        ]),
      )),
    );
  }

  Future<String?> _password({required bool confirm}) async {
    final first = TextEditingController();
    final again = TextEditingController();
    var visible = false;
    final result = await showDialog<String>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(confirm ? 'Encrypt device backup' : 'Unlock backup'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(confirm
                ? 'Choose and remember a password of at least 12 characters.'
                : 'Enter the password used to create the backup.'),
            const SizedBox(height: 12),
            TextField(
              controller: first, autofocus: true,
              obscureText: !visible, enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Backup password', border: OutlineInputBorder()),
            ),
            if (confirm) ...[
              const SizedBox(height: 12),
              TextField(
                controller: again, obscureText: !visible,
                enableSuggestions: false, autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Confirm password', border: OutlineInputBorder()),
              ),
            ],
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show password'),
              value: visible,
              onChanged: (v) => update(() => visible = v ?? false),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (first.text.length < 12) {
                  return;
                }
                if (confirm && first.text != again.text) {
                  return;
                }
                Navigator.pop(dialog, first.text);
              },
              child: Text(confirm ? 'Encrypt' : 'Unlock'),
            ),
          ],
        ),
      ),
    );
    first.dispose();
    again.dispose();
    return result;
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await task();
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } on MissingPluginException {
      if (mounted) {
        setState(() => _error =
            'Files backup is unavailable in this build. Update TapTether.');
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() =>
            _error = error.message ?? 'Cannot access the selected Files folder.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Backup could not finish. Check Files permissions and retry.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<String?> _getExportPassword() async {
    if (!_usePassword) return null;
    if (_rememberedPassword != null &&
        _rememberedPassword!.length >= 12) {
      return _rememberedPassword;
    }
    final entered = await _password(confirm: true);
    if (entered == null) return null;
    await _secure.write(key: _passwordKey, value: entered);
    _rememberedPassword = entered;
    return entered;
  }

  Future<void> _toggleProtection(bool enabled) => _run(() async {
    if (enabled == _usePassword) return;
    if (!enabled) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Disable password protection?'),
          content: const Text('Without a password, the backup file is not '
              'encrypted. Anyone with it could access your device '
              'credentials and SSH keys.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false),
                child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialog, true),
                child: const Text('Continue')),
          ],
        ),
      );
      if (approved != true || !mounted) return;
      await _secure.write(key: _noPasswordKey, value: 'true');
    } else {
      final newPassword = await _getExportPasswordForChange();
      if (newPassword == null || !mounted) return;
      await _secure.delete(key: _noPasswordKey);
    }
    _usePassword = enabled;
    if (_auto.enabled) {
      await _auto.setProtection(_usePassword ? _rememberedPassword : null);
      await _auto.backupNow(force: true);
    }
    if (mounted) setState(() {});
  });

  Future<String?> _getExportPasswordForChange() async {
    if (_rememberedPassword != null) return _rememberedPassword;
    final entered = await _password(confirm: true);
    if (entered == null) return null;
    await _secure.write(key: _passwordKey, value: entered);
    _rememberedPassword = entered;
    return entered;
  }

  Future<void> _export() => _run(() async {
    if (!await AppSecurity.instance.authenticate(context,
        reason: 'Authorize exporting device credentials')) {
      return;
    }
    if (!mounted) {
      return;
    }
    final entries = await _store.snapshot();
    if (entries.isEmpty) {
      throw StateError('There are no saved credentials to back up.');
    }
    final password = await _getExportPassword();
    if ((_usePassword && password == null) || !mounted) {
      return;
    }
    final encrypted = _usePassword
        ? await DeviceBackupCodec.encrypt(entries, password!)
        : DeviceBackupCodec.exportUnprotected(entries);
    if (!mounted) {
      return;
    }
    final day = DateTime.now().toUtc().toIso8601String().split('T').first;
    final location = await FilePicker.platform.saveFile(
      dialogTitle: 'Save TapTether encrypted device backup',
      fileName: 'TapTether-Devices-$day.ttbackup',
      type: FileType.custom,
      allowedExtensions: const ['ttbackup'],
      bytes: encrypted,
    );
    if (!mounted || location == null) {
      return;
    }
    _lastManualLocation = location;
    await _secure.write(key: _lastManualKey, value: location);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Backup saved to Files.')),
    );
  });

  Future<void> _import() => _run(() async {
    if (!await AppSecurity.instance.authenticate(context,
        reason: 'Authorize restoring device credentials')) {
      return;
    }
    if (!mounted) {
      return;
    }
    final selection = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['ttbackup'],
      allowMultiple: false,
      withData: true,
    );
    if (selection == null || selection.files.isEmpty || !mounted) {
      return;
    }
    final picked = selection.files.single;
    if (picked.size > DeviceBackupCodec.maxFileBytes) {
      throw const FormatException('Backup file exceeds size limit.');
    }
    Uint8List? bytes = picked.bytes;
    if (bytes == null && picked.path != null) {
      bytes = await File(picked.path!).readAsBytes();
    }
    if (bytes == null || bytes.length > DeviceBackupCodec.maxFileBytes) {
      throw const FormatException('Unable to read selected backup.');
    }
    if (!mounted) {
      return;
    }
    // Read the file format first. Unprotected backups need no password;
    // encrypted backups first try the passphrase saved on this phone.
    Map<String, String> verified;
    if (DeviceBackupCodec.needsPassword(bytes)) {
      if (_rememberedPassword != null) {
        try {
          verified = await DeviceBackupCodec.restoreFile(bytes,
              password: _rememberedPassword);
        } on FormatException {
          if (!mounted) return;
          final password = await _password(confirm: false);
          if (password == null) return;
          verified = await DeviceBackupCodec.restoreFile(bytes,
              password: password);
        }
      } else {
        final password = await _password(confirm: false);
        if (password == null) return;
        verified = await DeviceBackupCodec.restoreFile(bytes,
            password: password);
      }
    } else {
      verified = await DeviceBackupCodec.restoreFile(bytes);
    }
    if (!mounted) {
      return;
    }
    final existing = await _store.snapshot();
    if (!mounted) {
      return;
    }
    final existingWarning = existing.isNotEmpty
        ? '\n\nYou already have saved settings. Back those up first '
          'if you want to keep them.'
        : '';
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Restore saved devices?'),
        content: Text('Restore ${verified.length} encrypted pairing, '
            'identity and settings records. Matching records in this '
            'installation will be overwritten.$existingWarning'
            '\n\nYour app PIN is not changed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Restore')),
        ],
      ),
    );
    if (approved != true || !mounted) {
      return;
    }
    await _store.restore(verified);
    await widget.onRestored?.call();
    if (!mounted) {
      return;
    }
    await _refresh();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Devices restored. Saved devices will be '
          'checked on your current Wi-Fi.'),
    ));
  });

  Future<void> _toggleAutomatic(bool enable) => _run(() async {
    if (!enable) {
      await _auto.disable();
      return;
    }
    if (!_auto.folderAvailable) {
      final selected = await _auto.chooseFolder();
      if (!selected || !mounted) return;
    }
    final password = await _getExportPassword();
    if ((_usePassword && password == null) || !mounted) return;
    await _auto.enable(password);
    if (_auto.lastError != null) {
      throw StateError(_auto.lastError!);
    }
  });

  Future<void> _changeFolder() => _run(() async {
    final changed = await _auto.chooseFolder();
    if (changed && _auto.enabled &&
        !await _auto.backupNow(force: true)) {
      throw StateError('Cannot save to the selected folder.');
    }
  });

  Future<void> _backupAutomaticallyNow() => _run(() async {
    final saved = await _auto.backupNow(force: true);
    if (!saved) {
      throw StateError(_auto.lastError ??
          'Cannot verify the encrypted backup write.');
    }
  });

  @override
  void dispose() {
    _auto.removeListener(_automaticChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Device backups')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      const Text('Keep your devices after reinstalling.'),
      TextButton.icon(
        onPressed: _entries == null ? null : _showContents,
        icon: const Icon(Icons.info_outline, size: 18),
        label: Text('${_entries ?? 0} saved records · View contents'),
      ),
      if (_busy || _auto.busy) const LinearProgressIndicator(),
      if (_error != null) Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(_error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Protect with password'),
        subtitle: Text(_usePassword
            ? (_rememberedPassword == null
                ? 'Set once, then back up with one tap'
                : 'Remembered securely on this phone')
            : 'Off · Backup file is not encrypted'),
        value: _usePassword,
        onChanged: _busy ? null : _toggleProtection,
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: _busy ? null : _export,
        icon: const Icon(Icons.backup_outlined),
        label: const Text('Back up now'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _busy ? null : _import,
        icon: const Icon(Icons.restore_outlined),
        label: const Text('Restore backup'),
      ),
      if (_lastManualLocation != null) ...[
        const SizedBox(height: 8),
        Text('Last manual save: $_lastManualLocation',
            style: Theme.of(context).textTheme.bodySmall),
      ],
      const Divider(height: 28),
      if (Platform.isIOS) ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Automatic backup'),
          subtitle: Text(_auto.enabled ? 'On · Files folder selected'
              : 'Off · Save changes while the app is open'),
          value: _auto.enabled,
          onChanged: _busy || _auto.busy ? null : _toggleAutomatic,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.folder_outlined),
          title: const Text('Backup location'),
          subtitle: Text(_auto.folderLocation ?? 'Not selected'),
          trailing: TextButton(
            onPressed: _busy || _auto.busy ? null : _changeFolder,
            child: Text(_auto.folderName == null ? 'Choose' : 'Change'),
          ),
        ),
        if (_auto.lastFileName != null)
          Text('Latest: ${_auto.lastFileName}',
              style: Theme.of(context).textTheme.bodySmall),
        if (_auto.lastBackup != null)
          Text('Saved: ${_auto.lastBackup!.toLocal().toString().substring(0, 16)}',
              style: Theme.of(context).textTheme.bodySmall),
        if (_auto.enabled) TextButton.icon(
          onPressed: _busy || _auto.busy
              ? null : _backupAutomaticallyNow,
          icon: const Icon(Icons.sync_outlined),
          label: const Text('Back up again'),
        ),
        if (_auto.lastError != null)
          Text(_auto.lastError!, style: TextStyle(
              color: Theme.of(context).colorScheme.error)),
      ],
      if (!_usePassword)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('Anyone with a backup file can read its credentials.',
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
    ]),
  );
}
