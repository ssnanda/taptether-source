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
  const AppLockGate({
    super.key,
    required this.child,
    this.biometricVerifierForTesting,
  });
  final Widget child;

  /// Test-only biometric callback to verify lock-screen behavior without
  /// invoking a device's real Face ID / Touch ID enrollment.
  @visibleForTesting
  final Future<bool> Function(String reason)? biometricVerifierForTesting;
  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate>
    with WidgetsBindingObserver {
  final _security = AppSecurity.instance;
  DateTime? _backgroundedAt;
  final _pin = TextEditingController();
  final _pinFocus = FocusNode();
  String? _unlockError;
  bool _unlockBusy = false;
  bool _autoBiometricAttempted = false;
  bool _pinFallbackVisible = false;
  bool _wasUnlocked = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _security.addListener(_onChanged);
    _security.load();
  }

  void _onChanged() {
    if (_security.ready) {
      // Reset the one-shot prompt only when transitioning to a new locked
      // session. A failed or canceled Face ID prompt must NOT loop.
      if (_security.unlocked || _wasUnlocked) {
        _autoBiometricAttempted = false;
        _pinFallbackVisible = false;
        _unlockError = null;
        _pin.clear();
      }
      _wasUnlocked = _security.unlocked;
    }
    if (mounted) setState(() {});
  }

  void _scheduleAutomaticBiometrics() {
    if (_autoBiometricAttempted || _unlockBusy ||
        !_security.ready || _security.unlocked ||
        !_security.enabled || !_security.biometricEnabled ||
        _security.loadError != null) {
      return;
    }
    _autoBiometricAttempted = true;
    // Call local_auth only after this lock screen has been laid out.
    // Do not invoke OS biometrics inside build(), and never repeat the
    // automatic attempt on a rebuild or on lifecycle notifications from
    // the native Face ID sheet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _security.ready && !_security.unlocked &&
          _security.enabled && _security.biometricEnabled &&
          _security.loadError == null && !_unlockBusy) {
        _unlockWithBiometrics();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Native biometric sheets can transition the app lifecycle; they are
    // not a fresh background/foreground event requiring another unlock.
    if (_security.authenticating || _unlockBusy) return;
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
    _pin.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  Future<void> _unlockWithPin() async {
    if (_unlockBusy) return;
    setState(() { _unlockBusy = true; _unlockError = null; });
    try {
      if (await _security.verifyPin(_pin.text)) {
        _pin.clear();
        _security.unlock();
      } else {
        if (mounted) {
          setState(() =>
              _unlockError = _security.lockoutMessage ?? 'Incorrect PIN.');
        }
      }
    } finally {
      if (mounted) setState(() => _unlockBusy = false);
    }
  }

  Future<void> _unlockWithBiometrics() async {
    if (_unlockBusy || _security.unlocked || !_security.biometricEnabled) {
      return;
    }
    setState(() { _unlockBusy = true; _unlockError = null; });
    try {
      final verify = widget.biometricVerifierForTesting ??
          _security.verifyBiometrics;
      if (await verify('Unlock TapTether')) {
        if (mounted && _security.enabled && !_security.unlocked) {
          _security.unlock();
        }
      } else if (mounted) {
        // Face ID failed, was canceled, locked out, or isn't available.
        // Offer the existing six-digit PIN instead of retrying silently.
        setState(() {
          _pinFallbackVisible = true;
          _unlockError = 'Face ID / Touch ID was not completed. Use your PIN.';
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_security.unlocked) _pinFocus.requestFocus();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _pinFallbackVisible = true;
          _unlockError = 'Biometric unlock unavailable. Use your PIN.';
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_security.unlocked) _pinFocus.requestFocus();
        });
      }
    } finally {
      if (mounted) setState(() => _unlockBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_security.ready) {
      return const Material(child: Center(
          child: CircularProgressIndicator()));
    }
    if (!_security.unlocked) {
      _scheduleAutomaticBiometrics();
      final showPin = !_security.biometricEnabled || _pinFallbackVisible;
      return Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(child: Center(child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_outline, size: 64),
            const SizedBox(height: 16),
            Text('Unlock TapTether',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(_security.loadError ??
                'Your devices, keys and credentials remain private.',
                textAlign: TextAlign.center),
            const SizedBox(height: 20),
            if (_security.loadError != null)
              FilledButton(onPressed: _security.load,
                  child: const Text('Retry secure storage'))
            else ...[
              if (_security.biometricEnabled && !showPin)
                Column(mainAxisSize: MainAxisSize.min, children: [
                  if (_unlockBusy)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: CircularProgressIndicator(),
                    ),
                  const Text('Checking Face ID / Touch ID…'),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _unlockBusy ? null : () {
                      setState(() => _pinFallbackVisible = true);
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _pinFocus.requestFocus();
                      });
                    },
                    child: const Text('Use PIN instead'),
                  ),
                ]),
              if (showPin) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: TextField(
                    controller: _pin,
                    focusNode: _pinFocus,
                    autofocus: !_security.biometricEnabled,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(
                        labelText: 'Six-digit app PIN', counterText: ''),
                    onSubmitted: (_) => _unlockWithPin(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _unlockBusy ? null : _unlockWithPin,
                  icon: const Icon(Icons.lock_open),
                  label: const Text('Unlock with PIN'),
                ),
                if (_security.biometricEnabled) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _unlockBusy ? null : _unlockWithBiometrics,
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('Try Face ID / Touch ID again'),
                  ),
                ],
              ],
              if (_unlockError != null) Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_unlockError!, textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
              ),
            ],
          ]),
        ))),
      );
    }
    return widget.child;
  }

}
