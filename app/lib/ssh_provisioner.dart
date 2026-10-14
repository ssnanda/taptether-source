import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';

import 'phone_ssh_keys.dart';
import 'ssh_host_trust.dart';
import 'ubuntu_install_validation.dart';
import 'ubuntu_install_error.dart';

enum SshLoginMethod { password, phoneKey }

class SshInstallRequest {
  const SshInstallRequest({
    required this.host, required this.username, required this.sshPassword,
    required this.sudoPassword,
    this.loginMethod = SshLoginMethod.password,
    this.authorizePhoneKey = false, this.sshKeyId,
  });
  final String host;
  final String username;
  final String sshPassword;
  final String sudoPassword;
  final SshLoginMethod loginMethod;
  final bool authorizePhoneKey;
  final String? sshKeyId;
}

class InstalledAgent {
  const InstalledAgent(this.host, this.token, this.fingerprint);
  final String host;
  final String token;
  final String fingerprint;
}

/// Installs a bundled, SHA-verified Ubuntu package using authenticated SSH.
/// Trusts a host key only on the first successful SSH login, then pins it in
/// protected storage. Unexpected later changes are never silently accepted.
class UbuntuSshProvisioner {
  static Future<InstalledAgent> install(SshInstallRequest input, {
    bool updateOnly = false,
    void Function(String step)? onProgress,
    SshHostTrustStore? hostTrustStore,
  }) async {
    void progress(String step) => onProgress?.call(step);
    progress('Checking connection details');
    if (!validUbuntuLanIp(input.host)) {
      throw const FormatException('Enter a valid private LAN IPv4 address '
          'with four dot-separated numbers.');
    }
    if (!RegExp(r'^[a-z_][a-z0-9_-]{0,30}$').hasMatch(input.username)) {
      throw const FormatException('Invalid Ubuntu username.');
    }
    if (input.loginMethod == SshLoginMethod.password &&
        input.sshPassword.isEmpty) {
      throw const FormatException('SSH login password required.');
    }
    if (input.loginMethod == SshLoginMethod.phoneKey &&
        !await PhoneSshKeyStore().exists) {
      throw const FormatException('Create or import a phone SSH key first.');
    }
    final trust = hostTrustStore ?? SshHostTrustStore();
    final savedFingerprint = await trust.trustedFingerprint(input.host);
    final identities = input.loginMethod == SshLoginMethod.phoneKey
        ? await PhoneSshKeyStore().authenticationIdentities(id: input.sshKeyId)
        : null;
    progress('Connecting to the SSH server');
    final socket = await SSHSocket.connect(input.host, 22)
        .timeout(const Duration(seconds: 8));
    String? observedFingerprint;
    bool hostKeyChanged = false;
    final client = SSHClient(
      socket, username: input.username,
      identities: identities,
      onPasswordRequest: input.loginMethod == SshLoginMethod.password
          ? () => input.sshPassword
          : null,
      handshakeTimeout: const Duration(seconds: 12),
      authTimeout: const Duration(seconds: 12),
      onVerifyHostKey: (_, fingerprint) {
        final received = utf8.decode(fingerprint);
        observedFingerprint = received;
        if (!SshHostTrustStore.validFingerprint(received)) return false;
        if (savedFingerprint != null && savedFingerprint != received) {
          hostKeyChanged = true;
          return false;
        }
        return true;
      },
    );
    String? stage;
    SftpClient? sftp;
    try {
      progress('Verifying SSH identity and signing in');
      try {
        await client.authenticated.timeout(const Duration(seconds: 20));
      } on TimeoutException {
        throw StateError('SSH sign-in timed out. Check the SSH username, '
            'that port 22 is reachable, and the selected login method.');
      } catch (_) {
        if (hostKeyChanged) {
          throw StateError('The SSH identity of this computer has changed. '
              'Connection blocked; TapTether will not automatically trust a '
              'different server at this address.');
        }
        if (input.loginMethod == SshLoginMethod.phoneKey) {
          throw StateError('SSH sign-in failed. The selected phone SSH key '
              'may not be authorized for this Ubuntu username. '
              'Try SSH password login, or authorize this phone public key '
              'for that user on Ubuntu.');
        }
        throw StateError('SSH sign-in failed. Check the Ubuntu username, '
            'SSH password and SSH server authentication settings.');
      }
      final observed = observedFingerprint;
      if (observed == null) {
        throw StateError('SSH server identity unavailable; refusing install.');
      }
      await trust.rememberAuthenticated(input.host, observed);
      if (input.loginMethod == SshLoginMethod.password &&
          input.authorizePhoneKey) {
        await authorizePhoneKey(client, input.sshKeyId);
      }
      progress('Checking Ubuntu architecture');
      final architectureResult = await client.runWithResult('dpkg --print-architecture');
      if (architectureResult.exitCode != 0) {
        throw StateError('Target is not Ubuntu/Debian.');
      }
      final arch = utf8.decode(architectureResult.stdout).trim();
      if (arch != 'amd64' && arch != 'arm64') {
        throw StateError('Unsupported Ubuntu architecture.');
      }
      if (updateOnly) {
        final existing = await client.runWithResult(
            'test -x /usr/local/bin/taptether-agent');
        if (existing.exitCode != 0) {
          throw StateError('[NOT-INSTALLED] No TapTether agent found on Ubuntu. '
              'Choose Install Agent instead of Update Agent.');
        }
      }
      final manifest = jsonDecode(
          await rootBundle.loadString('assets/agents/manifest.json'));
      final installers = manifest['installers'];
      if (installers is! List) throw const FormatException('Missing installer manifest.');
      final matches = installers.whereType<Map>().where(
        (item) => item['platform'] == 'ubuntu' && item['arch'] == arch,
      );
      if (matches.length != 1) throw StateError('Bundled Ubuntu agent unavailable.');
      final entry = matches.single;
      final filename = entry['filename'];
      final asset = entry['asset'];
      final expectedHash = entry['sha256'];
      if (filename is! String || asset is! String || expectedHash is! String ||
          !RegExp(r'^taptether-agent_[0-9a-zA-Z.+_-]+_(amd64|arm64)[.]deb$')
              .hasMatch(filename)) {
        throw const FormatException('Invalid package metadata.');
      }
      progress('Verifying bundled installer');
      final deb = await _loadBytes(asset);
      if (sha256.convert(deb).toString() != expectedHash) {
        throw StateError('Bundled Ubuntu agent SHA-256 mismatch.');
      }
      final mktemp = await client.runWithResult(
        'mktemp -d /tmp/taptether-phone.XXXXXXXX');
      if (mktemp.exitCode != 0) throw StateError('Cannot create SSH staging area.');
      stage = utf8.decode(mktemp.stdout).trim();
      if (!RegExp(r'^/tmp/taptether-phone[.][A-Za-z0-9]{8}$').hasMatch(stage)) {
        throw StateError('Unsafe staging directory.');
      }
      progress('Uploading Ubuntu agent securely');
      sftp = await client.sftp();
      Future<void> upload(String name, Uint8List bytes) async {
        final file = await sftp!.open('$stage/$name',
            mode: SftpFileOpenMode.create |
                SftpFileOpenMode.write | SftpFileOpenMode.truncate);
        try {
          await file.writeBytes(bytes);
        } finally {
          await file.close();
        }
      }
      await upload(filename, deb);
      for (final name in [
        '4-ubuntu-desktop-setup.sh',
        '7-tt-update-ubuntu.sh',
        'taptether_tray.py',
        'TapTether-icon.png',
      ]) {
        await upload(name, await _loadBytes('assets/agents/$name'));
      }
      progress('Installing agent and starting service');
      final sudoCheck = input.sudoPassword.isEmpty
          ? 'sudo -n -v'
          : 'sudo -k && sudo -S -p "" -v';
      // Keep staging private; isolate the dpkg output from sudo-password
      // authentication and pairing logs. Only a sanitized package diagnostic
      // may appear in the iPhone failure report.
      final command = '''
if ! ( $sudoCheck ); then exit 41; fi
if ! sudo -n -v; then exit 41; fi
if ! command -v dpkg-deb >/dev/null 2>&1; then
  printf 'TAPTETHER_DPKG_BEGIN\n'
  printf 'dpkg-deb: error: package inspection utility is unavailable\n'
  printf 'TAPTETHER_DPKG_END\n'
  exit 42
fi
if ! dpkg-deb --info '$stage/$filename' >/dev/null 2>&1; then
  printf 'TAPTETHER_DPKG_BEGIN\n'
  printf 'dpkg-deb: error: package archive failed preflight inspection\n'
  printf 'TAPTETHER_DPKG_END\n'
  exit 42
fi
if sudo -n env DEBIAN_FRONTEND=noninteractive dpkg --install '$stage/$filename' > '$stage/dpkg-install.log' 2>&1; then
  :
else
  dpkg_exit=\$?
  printf 'TAPTETHER_DPKG_BEGIN\n'
  tail -c 6000 '$stage/dpkg-install.log'
  printf '\nTAPTETHER_DPKG_END\nTAPTETHER_DPKG_STATUS:%s\n' "\$dpkg_exit"
  exit 42
fi
if ! bash '$stage/4-ubuntu-desktop-setup.sh' install; then exit 43; fi
''';
      final session = await client.execute(command, pty: const SSHPtyConfig());
      if (input.sudoPassword.isNotEmpty) {
        session.stdin.add(Uint8List.fromList(
            utf8.encode('${input.sudoPassword}\n')));
      }
      final bytes = <int>[];
      await Future.wait([
        session.stdout.forEach(bytes.addAll),
        session.stderr.forEach(bytes.addAll),
      ]).timeout(const Duration(minutes: 5));
      final code = await session.waitForExit(timeout: const Duration(seconds: 10));
      if (code != 0) {
        // Never display raw installer output; it contains pairing secrets.
        switch (code) {
          case 41:
            throw StateError('[SUDO-AUTH] Ubuntu sudo authorization failed. Enter the '
                'Ubuntu sudo password (separate from your SSH key), or '
                'enable passwordless sudo for the account.');
          case 42:
            // Classify dpkg errors without showing unfiltered output.
            // Subsequent setup logs may contain pairing credentials.
            throw StateError(ubuntuPackageFailureMessage(
                utf8.decode(bytes, allowMalformed: true)));
          case 43:
            throw StateError('[SETUP-SERVICE] The Ubuntu agent setup failed after package '
                'installation. Check systemd and /dev/uinput permissions '
                'using: sudo systemctl status taptether-agent --no-pager');
          default:
            throw StateError('Installation stopped unexpectedly (exit '
                '${code ?? "unknown"}). Check Ubuntu SSH and service logs.');
        }
      }
      progress('Reading agent pairing details');
      final output = utf8.decode(bytes, allowMalformed: true);
      final t = RegExp(r'Pairing token:\s*([a-f0-9]{48})').firstMatch(output);
      final f = RegExp(r'TLS certificate SHA-256 fingerprint:\s*([A-Fa-f0-9]{64})')
          .firstMatch(output);
      if (t == null || f == null) {
        throw StateError('Installed, but pairing data was not returned. '
            'Run taptetherctl pairing over SSH.');
      }
      return InstalledAgent(input.host, t.group(1)!, f.group(1)!.toUpperCase());
    } finally {
      if (sftp != null) await sftp.close();
      if (stage != null) {
        try {
          await client.run('rm -rf -- $stage');
        } catch (_) {
          // A failed cleanup must not conceal the primary installation error.
        }
      }
      await client.close();
    }
  }

  /// Only an SSH connection to a separately verified host can add the public
  /// key after successful existing user authentication. No private key leaves
  /// the phone.
  static Future<void> authorizePhoneKey(SSHClient client, String? keyId) async {
    final publicKey = await PhoneSshKeyStore().publicKeyLine(id: keyId);
    final valid = publicKey != null &&
        RegExp(r'^ssh-ed25519 [A-Za-z0-9+/=]+ taptether-mobile')
            .firstMatch(publicKey)?.group(0) == publicKey;
    if (!valid) {
      throw StateError('Generate or import a valid phone SSH key first.');
    }
    final quotedKey = "'$publicKey'";
    final command = 'umask 077; mkdir -p "\$HOME/.ssh" && '
        'chmod 700 "\$HOME/.ssh" && touch "\$HOME/.ssh/authorized_keys" && '
        'chmod 600 "\$HOME/.ssh/authorized_keys" && '
        '(grep -Fqx -- $quotedKey "\$HOME/.ssh/authorized_keys" || '
        'printf "%s\\n" $quotedKey >> "\$HOME/.ssh/authorized_keys")';
    final result = await client.runWithResult(command);
    if (result.exitCode != 0) {
      throw StateError('Could not authorize phone SSH public key on Ubuntu.');
    }
  }

  static Future<Uint8List> _loadBytes(String asset) async {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}
