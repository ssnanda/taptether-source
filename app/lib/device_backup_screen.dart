import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_security.dart';
import 'device_backup.dart';

class DeviceBackupScreen extends StatefulWidget {
  const DeviceBackupScreen({super.key, this.onRestored});
  final Future<void> Function()? onRestored;
  @override
  State<DeviceBackupScreen> createState() => _DeviceBackupScreenState();
}

class _DeviceBackupScreenState extends State<DeviceBackupScreen> {
  final _store = DeviceBackupStore();
  bool _busy = false;
  String? _error;
  int? _entries;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final data = await _store.snapshot();
      if (mounted) {
        setState(() => _entries = data.length);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Secure storage unavailable. Restore will work when '
            'device storage becomes available.');
      }
    }
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
    } catch (error) {
      if (mounted) {
        setState(() =>
            _error = 'Backup operation failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
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
    final password = await _password(confirm: true);
    if (password == null || !mounted) {
      return;
    }
    final encrypted = await DeviceBackupCodec.encrypt(entries, password);
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
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Encrypted backup saved outside TapTether. '
          'Keep it in iCloud Drive or another safe location.'),
    ));
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
    final password = await _password(confirm: false);
    if (password == null || !mounted) {
      return;
    }
    // Authenticate the entire file before overwriting any secure entry.
    final verified = await DeviceBackupCodec.decrypt(bytes, password);
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Device Backup & Restore')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      const Icon(Icons.backup_outlined, size: 44),
      const SizedBox(height: 10),
      Text('Keep your devices after reinstalling',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 14),
      const Text('Encrypted backups include computer and LG/Samsung '
          'TV pairings, phone identity, SSH keys, network labels and '
          'remote preferences. Deleting the app may erase its local data.'),
      const SizedBox(height: 16),
      const Text('Save the .ttbackup file to iCloud Drive or another '
          'folder outside TapTether. This uses no TapTether cloud server.'),
      const SizedBox(height: 16),
      if (_entries != null)
        Text('Saved secure-storage records: $_entries',
            style: Theme.of(context).textTheme.bodySmall),
      if (_busy) const LinearProgressIndicator(),
      if (_error != null)
        Padding(padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(_error!, style: TextStyle(
              color: Theme.of(context).colorScheme.error))),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _busy ? null : _export,
        icon: const Icon(Icons.file_upload_outlined),
        label: const Text('Back up devices to Files'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _busy ? null : _import,
        icon: const Icon(Icons.file_download_outlined),
        label: const Text('Restore devices from backup'),
      ),
      const SizedBox(height: 18),
      const Text('This backup contains secret pairing tokens and '
          'SSH private keys. Keep the password safe. It cannot be reset. '
          'Make a new backup whenever you add or remove devices.'),
    ]),
  );
}
