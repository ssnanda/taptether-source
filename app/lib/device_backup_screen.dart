import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_security.dart';
import 'automatic_device_backup.dart';
import 'backup_preview.dart';
import 'backup_location_label.dart';
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
  List<Map<String, dynamic>> _backups = const [];

  void _automaticChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _auto.addListener(_automaticChanged);
    _refresh();
    _auto.initialize().then((_) => _loadBackups());
    _loadBackupOptions();
  }

  Future<void> _loadBackups() async {
    if (!Platform.isIOS) return;
    try {
      final list = await _auto.listBackups();
      if (mounted) setState(() => _backups = list);
    } catch (_) {
      if (mounted) setState(() => _backups = const []);
    }
  }

  Future<void> _openSaved(String filename) async {
    if (_busy || filename.isEmpty) return;
    late final Uint8List bytes;
    try {
      bytes = await _auto.readBackup(filename);
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Cannot read this backup. Check iCloud Drive and try again.');
      }
      return;
    }
    if (mounted) await _import(backupBytes: bytes, sourceName: filename);
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
    } on StateError catch (error) {
      if (mounted) {
        setState(() => _error = error.message.toString());
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
    if (Platform.isIOS) {
      if (!_auto.folderAvailable) {
        if (!await _auto.chooseFolder() || !mounted) return;
      }
      final filename = await _auto.saveManual(encrypted);
      await _loadBackups();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved $filename in TapTether.')),
      );
    } else {
      final stamp = DateTime.now().toUtc().toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-');
      final location = await FilePicker.platform.saveFile(
        dialogTitle: 'Save TapTether backup',
        fileName: 'TapTether-Devices-$stamp.ttbackup',
        type: FileType.custom,
        allowedExtensions: const ['ttbackup'],
        bytes: encrypted,
      );
      if (!mounted || location == null) return;
      _lastManualLocation = location;
      await _secure.write(key: _lastManualKey, value: location);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup saved to Files.')));
    }
  });

  /// Mandatory rollback point. A cancelled or failed write blocks restore.
  Future<String?> _createPreRestoreBackup(
      Map<String, String> existing) async {
    if (existing.isEmpty) return null;
    // An emergency backup always contains encrypted credentials, even when
    // ordinary manual backup password protection is turned off.
    final password = await _getExportPasswordForChange();
    if (password == null) return null;
    final bytes = await DeviceBackupCodec.encrypt(existing, password);
    if (!mounted) return null;
    if (Platform.isIOS) {
      if (!_auto.folderAvailable) {
        if (!await _auto.chooseFolder() || !mounted) return null;
      }
      final saved = await _auto.savePreRestore(bytes);
      await _loadBackups();
      return saved;
    }

    final stamp = DateTime.now().toUtc().toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final file = await FilePicker.platform.saveFile(
      dialogTitle: 'Save pre-restore safety backup',
      fileName: 'TapTether-PreRestore-$stamp.ttbackup',
      type: FileType.custom,
      allowedExtensions: const ['ttbackup'],
      bytes: bytes,
    );
    if (file == null) return null;
    // When the provider exposes a native path, verify the write size.
    final output = File(file);
    if (await output.exists() && await output.length() != bytes.length) {
      throw StateError('Pre-restore backup was not saved completely.');
    }
    return file;
  }

  Future<bool> _reviewBackup(
      Map<String, String> verified, String? sourceName) async {
    final preview = BackupPreview.fromRecords(verified);
    return await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Review backup'),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (sourceName != null)
                Text(sourceName,
                    style: Theme.of(dialog).textTheme.bodySmall),
              const SizedBox(height: 8),
              Text('${preview.deviceCount} devices · '
                   '${preview.recordCount} saved records',
                  style: Theme.of(dialog).textTheme.titleMedium),
              const SizedBox(height: 12),
              for (final group in preview.groups.entries)
                if (group.value.isNotEmpty) ...[
                  Text(group.key,
                      style: Theme.of(dialog).textTheme.titleSmall),
                  for (final name in group.value.take(12))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 3, 0, 3),
                      child: Row(children: [
                        const Icon(Icons.devices_outlined, size: 16),
                        const SizedBox(width: 8),
                        Expanded(child: Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                      ]),
                    ),
                  const SizedBox(height: 8),
                ],
              if (preview.deviceCount == 0)
                const Text('No named devices in this backup.'),
              if (preview.otherRecordCount > 0)
                Text('${preview.otherRecordCount} additional identity, '
                    'SSH, network or preference records'),
              const SizedBox(height: 10),
              const Text('Pairing secrets and private keys are '
                  'hidden from this preview.'),
            ],
          )),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Done')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialog, true),
            icon: const Icon(Icons.restore_outlined),
            label: const Text('Continue to restore')),
        ],
      ),
    ) ?? false;
  }

  Future<void> _import({Uint8List? backupBytes, String? sourceName}) =>
      _run(() async {
    if (!await AppSecurity.instance.authenticate(context,
        reason: 'Authorize restoring device credentials')) {
      return;
    }
    if (!mounted) {
      return;
    }
    Uint8List? bytes = backupBytes;
    if (bytes == null) {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['ttbackup'],
        allowMultiple: false,
        withData: true,
      );
      if (selection == null || selection.files.isEmpty || !mounted) return;
      final picked = selection.files.single;
      if (picked.size > DeviceBackupCodec.maxFileBytes) {
        throw const FormatException('Backup file exceeds size limit.');
      }
      bytes = picked.bytes;
      if (bytes == null && picked.path != null) {
        bytes = await File(picked.path!).readAsBytes();
      }
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
    // View first, with a separate explicit path to restore.
    if (!await _reviewBackup(verified, sourceName) || !mounted) return;
    final existing = await _store.snapshot();
    if (!mounted) return;

    // Fail closed. Any existing pairings and keys must be saved in an
    // encrypted PreRestore file before the import can mutate Keychain.
    String? safetyFile;
    if (existing.isNotEmpty) {
      safetyFile = await _createPreRestoreBackup(existing);
      if (safetyFile == null || !mounted) {
        if (mounted) {
          setState(() => _error = 'Restore cancelled. Current devices '
              'were not changed because a Pre-Restore backup was not saved.');
        }
        return;
      }
    }
    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(safetyFile == null
            ? 'Restore saved devices?' : 'Safety backup created'),
        content: Text(safetyFile == null
            ? 'No current saved-device records need protection. '
              'Restore ${verified.length} records? Your app PIN is unchanged.'
            : 'Saved your current devices in:\n$safetyFile'
              '\n\nYou can use that Pre-Restore backup to recover '
              'your previous pairings and settings.'
              '\n\nContinue restoring ${verified.length} records? '
              'Matching records will be overwritten. Your PIN stays unchanged.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Restore now')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
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
    if (!changed) return;
    if (_auto.enabled && !await _auto.backupNow(force: true)) {
      throw StateError('Cannot save to the selected folder.');
    }
    await _loadBackups();
  });

  @override
  void dispose() {
    _auto.removeListener(_automaticChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Device backups')),
    body: Column(children: [
      Expanded(child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        children: [
          ListTile(
            key: const ValueKey('backup-location'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Backup location'),
            subtitle: Text(
              backupLocationLabel(
                automaticFolder: _auto.folderLocation,
                manualPath: _lastManualLocation,
              ),
              maxLines: 1, overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              key: const ValueKey('backup-location-choose'),
              tooltip: 'Choose backup folder',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(
                width: 36, height: 36),
              padding: EdgeInsets.zero,
              onPressed: _busy || _auto.busy ? null : _changeFolder,
              icon: const Icon(Icons.folder_open_outlined, size: 21),
            ),
          ),
          const Divider(height: 22),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Password protection'),
            subtitle: _usePassword
                ? null : const Text('Backup file is not encrypted'),
            value: _usePassword,
            onChanged: _busy ? null : _toggleProtection,
          ),
          const SizedBox(height: 14),
          if (_busy || _auto.busy) const LinearProgressIndicator(),
          if (_error != null) Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_error!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error)),
          ),
          FilledButton.icon(
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.backup_outlined),
            label: const Text('Back up now'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _import(),
            icon: const Icon(Icons.restore_outlined),
            label: const Text('Restore from Files'),
          ),
          if (Platform.isIOS && _auto.folderAvailable) ...[
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: Text('Recent backups',
                style: Theme.of(context).textTheme.titleMedium)),
              Text('${_backups.length} saved',
                style: Theme.of(context).textTheme.bodySmall),
            ]),
            if (_backups.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No backups in this folder yet.'))
            else
              for (final item in _backups) ListTile(
                key: ValueKey('backup-entry-${item['filename']}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  (item['filename']?.toString() ?? '')
                      .contains('-PreRestore-')
                      ? Icons.shield_outlined : Icons.history_outlined),
                title: Text(() {
                  final time = DateTime.tryParse(item['date']?.toString() ?? '')
                      ?.toLocal();
                  if (time == null) return 'Saved backup';
                  return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
                      '${time.day.toString().padLeft(2, '0')}  '
                      '${time.hour.toString().padLeft(2, '0')}:'
                      '${time.minute.toString().padLeft(2, '0')}';
                }()),
                subtitle: Text((item['filename']?.toString() ?? '')
                    .contains('-PreRestore-') ? 'Pre-Restore safety backup'
                    : (item['filename']?.toString() ?? '')
                        .contains('-Manual-') ? 'Manual backup'
                    : 'Automatic backup'),
                trailing: IconButton(
                  tooltip: 'View backup',
                  icon: const Icon(Icons.visibility_outlined, size: 21),
                  onPressed: _busy ? null : () => _openSaved(
                    item['filename']?.toString() ?? ''),
                ),
                onTap: _busy ? null : () => _openSaved(
                    item['filename']?.toString() ?? ''),
              ),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _entries == null ? null : _showContents,
              icon: const Icon(Icons.info_outline, size: 18),
              label: Text('${_entries ?? 0} saved records'),
            ),
          ),
        ],
      )),
      if (Platform.isIOS) SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Divider(height: 1),
              SwitchListTile(
                key: const ValueKey('automatic-backup'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Automatic backup'),
                value: _auto.enabled,
                onChanged: _busy || _auto.busy
                    ? null : _toggleAutomatic,
              ),
              if (_auto.lastError != null && _auto.enabled)
                Text(_auto.lastError!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
    ]),
  );
}
