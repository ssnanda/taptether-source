import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/ubuntu_uninstall_recovery.dart';

void main() {
  test('offline agent removal requires previously trusted SSH host key', () {
    expect(canStartOfflineUbuntuUninstall(
      agentVerified: false,
      previouslyTrustedSshFingerprint: null), isFalse);
    expect(canStartOfflineUbuntuUninstall(
      agentVerified: false,
      previouslyTrustedSshFingerprint: ''), isFalse);
    expect(canStartOfflineUbuntuUninstall(
      agentVerified: false,
      previouslyTrustedSshFingerprint:
          'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'), isTrue);
    // Live agent identity can still use the existing first-use SSH flow.
    expect(canStartOfflineUbuntuUninstall(
      agentVerified: true, previouslyTrustedSshFingerprint: null), isTrue);
  });

  test('uninstall diagnostics only return fixed nonsecret stages', () {
    expect(ubuntuUninstallFailureStage(
      'TAPTETHER_UNINSTALL_FAILURE_STAGE:stop-service'),
      'stop-service');
    expect(ubuntuUninstallFailureStage(
      'TAPTETHER_UNINSTALL_FAILURE_STAGE:remove-service-files'),
      'remove-service-files');
    expect(ubuntuUninstallFailureStage(
      'TAPTETHER_UNINSTALL_FAILURE_STAGE:reload-systemd'),
      'reload-systemd');
    expect(ubuntuUninstallFailureStage(
      'TAPTETHER_UNINSTALL_ENTER_STAGE:remove-package\n'
      'dpkg: error processing taptether-agent'), 'remove-package');
    expect(ubuntuUninstallFailureStage(
      'sudo: a password is required'), 'sudo-auth');
  });

  test('never echo secrets or arbitrary remote output to diagnostic UI', () {
    const raw = 'password=private-password\n'
        'Pairing token: 00112233445566778899\n'
        'TAPTETHER_UNINSTALL_FAILURE_STAGE:arbitrary-injected-label';
    final result = ubuntuUninstallFailureStage(raw);
    expect(result, 'system-or-sudo');
    expect(result, isNot(contains('password')));
    expect(result, isNot(contains('001122')));
  });
}
