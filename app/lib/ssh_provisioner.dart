import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';

import 'discovery.dart';

class SshInstallRequest {
  const SshInstallRequest({
    required this.host, required this.username, required this.sshPassword,
    required this.sudoPassword, required this.hostKeyFingerprint,
  });
  final String host;
  final String username;
  final String sshPassword;
  final String sudoPassword;
  final String hostKeyFingerprint;
}

class InstalledAgent {
  const InstalledAgent(this.host, this.token, this.fingerprint);
  final String host;
  final String token;
  final String fingerprint;
}

/// Installs a bundled, SHA-verified Ubuntu package using SSH with an
/// out-of-band VERIFIED SSH host key. SSH passwords are never saved.
class UbuntuSshProvisioner {
  static Future<InstalledAgent> install(SshInstallRequest input) async {
    if (!isPrivateIPv4(input.host)) {
      throw const FormatException('SSH target must be private IPv4.');
    }
    if (!RegExp(r'^[a-z_][a-z0-9_-]{0,30}$').hasMatch(input.username)) {
      throw const FormatException('Invalid Ubuntu username.');
    }
    final expected = input.hostKeyFingerprint.trim();
    if (!RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$').hasMatch(expected)) {
      throw const FormatException('Enter the verified SSH SHA256: fingerprint.');
    }
    if (input.sshPassword.isEmpty) {
      throw const FormatException('SSH login password required.');
    }
    final socket = await SSHSocket.connect(input.host, 22)
        .timeout(const Duration(seconds: 8));
    final client = SSHClient(
      socket, username: input.username,
      onPasswordRequest: () => input.sshPassword,
      handshakeTimeout: const Duration(seconds: 12),
      authTimeout: const Duration(seconds: 12),
      onVerifyHostKey: (_, fingerprint) => utf8.decode(fingerprint) == expected,
    );
    String? stage;
    SftpClient? sftp;
    try {
      await client.authenticated.timeout(const Duration(seconds: 20));
      final architectureResult = await client.runWithResult('dpkg --print-architecture');
      if (architectureResult.exitCode != 0) {
        throw StateError('Target is not Ubuntu/Debian.');
      }
      final arch = utf8.decode(architectureResult.stdout).trim();
      if (arch != 'amd64' && arch != 'arm64') {
        throw StateError('Unsupported Ubuntu architecture.');
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
        'TapTether-icon.png',
      ]) {
        await upload(name, await _loadBytes('assets/agents/$name'));
      }
      final sudoCheck = input.sudoPassword.isEmpty
          ? 'sudo -n -v'
          : 'sudo -k && sudo -S -p "" -v';
      final command = "$sudoCheck && sudo -n apt install -y '$stage/$filename' "
          "&& bash '$stage/4-ubuntu-desktop-setup.sh' install";
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
        // Never display raw installation logs: they include private pairing data.
        throw StateError('Installation failed (exit ${code ?? "unknown"}). '
            'Verify SSH, sudo, and systemd permissions.');
      }
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
          await client.run('rm -rf -- "$stage"');
        } catch (_) {
          // A failed cleanup must not conceal the primary installation error.
        }
      }
      await client.close();
    }
  }

  static Future<Uint8List> _loadBytes(String asset) async {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}
