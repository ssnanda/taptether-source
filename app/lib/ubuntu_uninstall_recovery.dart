/// Guards remote-destructive recovery when an agent service is broken.
/// SSH host-key pinning must have happened on a prior authenticated session.
/// The current SSH handshake must also match that exact stored fingerprint.
bool canStartOfflineUbuntuUninstall({
  required bool agentVerified,
  required String? previouslyTrustedSshFingerprint,
}) => agentVerified || (previouslyTrustedSshFingerprint != null &&
    previouslyTrustedSshFingerprint.isNotEmpty);

/// Recognize only fixed stage names. Never surface remote command output:
/// it may include passwords, private file paths, or pairing credentials.
String ubuntuUninstallFailureStage(String remoteOutput) {
  final exact = RegExp(
    r'TAPTETHER_UNINSTALL_FAILURE_STAGE:'
    r'(stop-service|remove-service-files|reload-systemd|remove-package)')
      .firstMatch(remoteOutput)?.group(1);
  if (exact != null) {
    return exact;
  }
  if (remoteOutput.contains('TAPTETHER_UNINSTALL_ENTER_STAGE:remove-package')) {
    return 'remove-package';
  }
  if (RegExp(r'(incorrect password|a password is required|authentication failure|sudo: .*password)',
      caseSensitive: false).hasMatch(remoteOutput)) {
    return 'sudo-auth';
  }
  return 'system-or-sudo';
}
