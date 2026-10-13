import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Optional app lock. PIN verifier lives only in OS secure storage; never cloud.
class AppSecurity extends ChangeNotifier {
  AppSecurity._();
  static final instance = AppSecurity._();
  final _storage = const FlutterSecureStorage();
  final _biometric = LocalAuthentication();
  static const _hash = 'taptether.lock.hash.v1';
  static const _salt = 'taptether.lock.salt.v1';
  static const _enabled = 'taptether.lock.enabled.v1';
  static const _bio = 'taptether.lock.bio.v1';
  static const _delay = 'taptether.lock.delay.v1';
  static const _attempts = 'taptether.lock.attempts.v1';
  static const _blocked = 'taptether.lock.blocked.v1';
  final _kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(), iterations: 180000, bits: 256);

  bool ready = false;
  bool enabled = false;
  bool biometricEnabled = false;
  bool unlocked = false;
  bool authenticating = false;
  int delaySeconds = 0;
  String? loadError;
  int _failures = 0;
  DateTime? _blockUntil;

  Future<void> load() async {
    ready = false;
    notifyListeners();
    try {
      enabled = (await _storage.read(key: _enabled)) == 'true';
      biometricEnabled = (await _storage.read(key: _bio)) == 'true';
      delaySeconds = int.tryParse(await _storage.read(key: _delay) ?? '') ?? 0;
      _failures = int.tryParse(await _storage.read(key: _attempts) ?? '') ?? 0;
      final block = int.tryParse(await _storage.read(key: _blocked) ?? '');
      _blockUntil = block == null ? null : DateTime.fromMillisecondsSinceEpoch(block);
      if (enabled && ((await _storage.read(key: _hash)) == null ||
          (await _storage.read(key: _salt)) == null)) {
        throw StateError('Missing app PIN configuration');
      }
      unlocked = !enabled;
      loadError = null;
    } catch (_) {
      enabled = true;
      unlocked = false;
      loadError = 'Secure storage unavailable. Retry once device access is restored.';
    } finally {
      ready = true;
      notifyListeners();
    }
  }

  static bool isValidPin(String pin) => RegExp(r'^\d{6}$').hasMatch(pin);

  Future<List<int>> _derive(String pin, List<int> salt) async =>
      (await _kdf.deriveKeyFromPassword(
          password: pin, nonce: salt)).extractBytes();

  Future<void> setPin(String pin) async {
    if (!isValidPin(pin)) throw const FormatException('PIN must be six digits.');
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final hash = await _derive(pin, salt);
    await _storage.write(key: _salt, value: base64Encode(salt));
    await _storage.write(key: _hash, value: base64Encode(hash));
    await _storage.write(key: _enabled, value: 'true');
    enabled = true;
    unlocked = true;
    _failures = 0;
    _blockUntil = null;
    await _storage.delete(key: _attempts);
    await _storage.delete(key: _blocked);
    notifyListeners();
  }

  Future<bool> verifyPin(String pin) async {
    if (!enabled || !isValidPin(pin)) return false;
    if (_blockUntil != null && DateTime.now().isBefore(_blockUntil!)) return false;
    final expected = await _storage.read(key: _hash);
    final storedSalt = await _storage.read(key: _salt);
    if (expected == null || storedSalt == null) return false;
    final wanted = base64Decode(expected);
    final got = await _derive(pin, base64Decode(storedSalt));
    var diff = wanted.length ^ got.length;
    for (var i = 0; i < wanted.length && i < got.length; i++) {
      diff |= wanted[i] ^ got[i];
    }
    if (diff == 0) {
      _failures = 0;
      _blockUntil = null;
      await _storage.delete(key: _attempts);
      await _storage.delete(key: _blocked);
      return true;
    }
    _failures++;
    if (_failures >= 5) {
      _failures = 0;
      _blockUntil = DateTime.now().add(const Duration(minutes: 1));
      await _storage.write(key: _blocked,
          value: _blockUntil!.millisecondsSinceEpoch.toString());
    }
    await _storage.write(key: _attempts, value: _failures.toString());
    return false;
  }

  String? get lockoutMessage => _blockUntil != null &&
      DateTime.now().isBefore(_blockUntil!)
      ? 'Too many attempts. Try again in one minute.' : null;

  Future<bool> supportsBiometrics() async {
    try {
      return await _biometric.canCheckBiometrics &&
          (await _biometric.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> verifyBiometrics(String reason) async {
    try {
      if (!await supportsBiometrics()) return false;
      return await _biometric.authenticate(
          localizedReason: reason,
          options: const AuthenticationOptions(
              biometricOnly: true, stickyAuth: true));
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setBiometrics(bool value) async {
    if (value && (!enabled || !await supportsBiometrics())) {
      throw StateError('Configure PIN and biometric enrollment first.');
    }
    await _storage.write(key: _bio, value: value.toString());
    biometricEnabled = value;
    notifyListeners();
  }

  Future<void> setDelay(int seconds) async {
    if (![0, 30, 60, 300].contains(seconds)) {
      throw const FormatException('Unsupported lock timeout.');
    }
    await _storage.write(key: _delay, value: seconds.toString());
    delaySeconds = seconds;
    notifyListeners();
  }

  Future<void> disable() async {
    await _storage.write(key: _enabled, value: 'false');
    await _storage.write(key: _bio, value: 'false');
    enabled = false;
    biometricEnabled = false;
    unlocked = true;
    notifyListeners();
  }

  void lock() {
    if (enabled && unlocked) {
      unlocked = false;
      notifyListeners();
    }
  }

  void unlock() {
    if (enabled) {
      unlocked = true;
      notifyListeners();
    }
  }

  Future<bool> authenticate(BuildContext context, {
    String reason = 'Unlock TapTether',
  }) async {
    if (!enabled) return true;
    if (authenticating) return false;
    authenticating = true;
    try {
      if (biometricEnabled && await verifyBiometrics(reason)) return true;
      if (!context.mounted) return false;
      final controller = TextEditingController();
      final pin = await showDialog<String>(
        context: context, barrierDismissible: false,
        builder: (dialog) => AlertDialog(
          title: const Text('TapTether PIN'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(reason),
            const SizedBox(height: 12),
            TextField(
              controller: controller, autofocus: true,
              keyboardType: TextInputType.number, obscureText: true,
              maxLength: 6,
              decoration: const InputDecoration(
                  labelText: '6-digit PIN', counterText: ''),
              onSubmitted: (value) => Navigator.pop(dialog, value),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog),
                child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialog, controller.text),
                child: const Text('Unlock')),
          ],
        ),
      );
      controller.dispose();
      if (pin == null) return false;
      final ok = await verifyPin(pin);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(lockoutMessage ?? 'Incorrect PIN.'),
        ));
      }
      return ok;
    } finally {
      authenticating = false;
    }
  }
}

/// Hides ALL device and key routes while authentication is required.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;
  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate>
    with WidgetsBindingObserver {
  final _security = AppSecurity.instance;
  DateTime? _backgroundedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _security.addListener(_onChanged);
    _security.load();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_security.authenticating) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      if (_backgroundedAt != null && _security.enabled &&
          DateTime.now().difference(_backgroundedAt!).inSeconds >=
              _security.delaySeconds) {
        _security.lock();
      }
      _backgroundedAt = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _security.removeListener(_onChanged);
    super.dispose();
  }

  Future<void> _unlock() async {
    if (await _security.authenticate(context)) _security.unlock();
  }

  @override
  Widget build(BuildContext context) {
    if (!_security.ready) {
      return const Scaffold(body: Center(
          child: CircularProgressIndicator()));
    }
    if (!_security.unlocked) {
      return Scaffold(
        appBar: AppBar(title: const Text('TapTether')),
        body: SafeArea(child: Center(child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_outline, size: 64),
            const SizedBox(height: 16),
            Text('Your devices stay private',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(_security.loadError ??
                'Use Face ID, Touch ID, or your six-digit PIN to continue.',
                textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _security.loadError != null
                  ? () => _security.load() : _unlock,
              icon: const Icon(Icons.lock_open),
              label: Text(_security.loadError != null
                  ? 'Retry secure storage' : 'Unlock TapTether'),
            ),
          ]),
        ))),
      );
    }
    return widget.child;
  }
}
