import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'device_backup.dart';

/// User-opt-in, app-awake encrypted backup to a user-selected Files folder.
/// The iOS file provider performs eventual iCloud synchronization. This class
/// never claims that the file has already uploaded to Apple's servers.
class AutomaticDeviceBackup extends ChangeNotifier {
  AutomaticDeviceBackup._();
  static final instance = AutomaticDeviceBackup._();

  static const _channel = MethodChannel('taptether.device_backup.folder.v1');
  static const _passwordKey = 'taptether.auto-backup.password.v1';
  static const _digestKey = 'taptether.auto-backup.last-digest.v1';
  static const _timeKey = 'taptether.auto-backup.last-saved.v1';
  static const _fileKey = 'taptether.auto-backup.last-file.v1';
  static const _withoutPasswordKey = 'taptether.auto-backup.no-password.v1';

  final _secure = const FlutterSecureStorage();
  final _store = DeviceBackupStore();
  Timer? _poll;
  Timer? _scheduled;
  bool _initialized = false;
  bool _busy = false;
  bool _enabled = false;
  bool _folderAvailable = false;
  String? _folderName;
  String? _folderLocation;
  String? _lastFileName;
  bool _withoutPassword = false;
  DateTime? _lastBackup;
  String? _lastError;
  String? _lastDigest;

  bool get enabled => _enabled;
  bool get folderAvailable => _folderAvailable;
  bool get busy => _busy;
  String? get folderName => _folderName;
  String? get folderLocation => _folderLocation;
  String? get lastFileName => _lastFileName;
  bool get withoutPassword => _withoutPassword;
  DateTime? get lastBackup => _lastBackup;
  String? get lastError => _lastError;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    if (!Platform.isIOS) {
      return;
    }
    try {
      final secret = await _secure.read(key: _passwordKey);
      _withoutPassword =
          await _secure.read(key: _withoutPasswordKey) == 'true';
      _enabled = _withoutPassword || (secret != null && secret.length >= 12);
      _lastDigest = await _secure.read(key: _digestKey);
      _lastFileName = await _secure.read(key: _fileKey);
      final rawTime = await _secure.read(key: _timeKey);
      _lastBackup = rawTime == null ? null : DateTime.tryParse(rawTime);
      await refreshFolder();
    } catch (error) {
      _lastError = 'Cannot read backup settings: $error';
    }
    notifyListeners();
    _poll ??= Timer.periodic(const Duration(seconds: 60), (_) {
      requestSoon();
    });
    if (_enabled) {
      requestSoon();
    }
  }

  Future<void> refreshFolder() async {
    if (!Platform.isIOS) return;
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('status');
      _folderAvailable = info?['available'] == true;
      _folderName = info?['folder']?.toString();
      _folderLocation = info?['location']?.toString() ??
          (_folderName == null ? null : 'Files / $_folderName');
    } on MissingPluginException {
      _folderAvailable = false;
      _lastError = 'Update TapTether to enable automatic Files backup.';
    } catch (error) {
      _folderAvailable = false;
      _lastError = 'Unable to access selected folder: $error';
    }
    notifyListeners();
  }

  /// Must be called directly from a user action to show the iOS picker.
  Future<bool> chooseFolder() async {
    if (!Platform.isIOS) {
      throw StateError('Automatic Files backup is currently iOS-only.');
    }
    final chosen = await _channel.invokeMethod<bool>('selectFolder') ?? false;
    await refreshFolder();
    return chosen && _folderAvailable;
  }

  Future<void> enable(String? password) async {
    if (!Platform.isIOS) {
      throw StateError('Automatic Files backup is currently iOS-only.');
    }
    if (password != null && password.length < 12) {
      throw const FormatException('Backup password must be at least 12 characters.');
    }
    await refreshFolder();
    if (!_folderAvailable) {
      throw StateError('Choose an accessible iCloud Drive folder first.');
    }
    await setProtection(password);
    _enabled = true;
    notifyListeners();
    if (!await backupNow(force: true)) {
      final message = _lastError ?? 'Could not save automatic backup.';
      await disable();
      throw StateError(message);
    }
  }

  Future<void> setProtection(String? password) async {
    if (password != null && password.length < 12) {
      throw const FormatException('Backup password must be at least 12 characters.');
    }
    if (password == null) {
      await _secure.delete(key: _passwordKey);
      await _secure.write(key: _withoutPasswordKey, value: 'true');
    } else {
      await _secure.write(key: _passwordKey, value: password);
      await _secure.delete(key: _withoutPasswordKey);
    }
    _withoutPassword = password == null;
    _lastDigest = null;
    _lastError = null;
    notifyListeners();
  }

  Future<void> disable() async {
    _scheduled?.cancel();
    await _secure.delete(key: _passwordKey);
    await _secure.delete(key: _withoutPasswordKey);
    _withoutPassword = false;
    _enabled = false;
    _lastError = null;
    notifyListeners();
  }

  void requestSoon() {
    if (!_initialized || !_enabled || !Platform.isIOS) {
      return;
    }
    _scheduled?.cancel();
    _scheduled = Timer(const Duration(seconds: 7), () {
      unawaited(backupNow());
    });
  }

  Future<bool> backupNow({bool force = false}) async {
    if (_busy || !_enabled || !Platform.isIOS) {
      return false;
    }
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      final password = await _secure.read(key: _passwordKey);
      if (!_withoutPassword && (password == null || password.length < 12)) {
        throw StateError('Backup password missing. Reconfigure backup protection.');
      }
      final selected = await _store.snapshot();
      if (selected.isEmpty) {
        throw StateError('No saved device credentials to back up.');
      }
      // Hash only in memory. Never record a key or private credential in logs.
      final ordered = SplayTreeMap<String, String>.from(selected);
      final digest = sha256.convert(utf8.encode(jsonEncode(ordered))).toString();
      if (!force && digest == _lastDigest) {
        return false;
      }

      final fileBytes = _withoutPassword
          ? DeviceBackupCodec.exportUnprotected(selected)
          : await DeviceBackupCodec.encrypt(selected, password!);
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'writeBackup',
        <String, Object>{'bytes': Uint8List.fromList(fileBytes)});
      if (response?['saved'] != true) {
        throw StateError('The backup destination did not verify the write.');
      }
      _lastDigest = digest;
      _lastBackup = DateTime.now().toUtc();
      _folderName = response?['folder']?.toString() ?? _folderName;
      _folderLocation = response?['location']?.toString() ??
          (_folderName == null ? null : 'Files / $_folderName');
      _lastFileName = response?['filename']?.toString();
      _folderAvailable = true;
      if (_lastFileName != null) {
        await _secure.write(key: _fileKey, value: _lastFileName!);
      }
      await _secure.write(key: _digestKey, value: digest);
      await _secure.write(
          key: _timeKey, value: _lastBackup!.toIso8601String());
      return true;
    } catch (error) {
      _lastError = 'Automatic backup not saved: $error';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
