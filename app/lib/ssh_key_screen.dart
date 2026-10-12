import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'phone_ssh_keys.dart';

class SshKeyScreen extends StatefulWidget {
  const SshKeyScreen({super.key});
  @override
  State<SshKeyScreen> createState() => _SshKeyScreenState();
}

class _SshKeyScreenState extends State<SshKeyScreen> {
  final _store = PhoneSshKeyStore();
  String? _publicLine;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final key = await _store.publicKeyLine();
      if (mounted) setState(() { _publicLine = key; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = 'Cannot load SSH key: $e');
    }
  }

  Future<void> _generate() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _store.generateIfMissing();
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = 'Key generation failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askPassphrase() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Unlock imported SSH key'),
        content: TextField(
          controller: controller, obscureText: true, autofocus: true,
          decoration: const InputDecoration(labelText: 'Private-key passphrase'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, controller.text),
              child: const Text('Unlock')),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<void> _import() async {
    if (_busy) return;
    final file = await FilePicker.platform.pickFiles(
      type: FileType.any, allowMultiple: false, withData: true,
    );
    if (file == null || file.files.isEmpty) return;
    final bytes = file.files.single.bytes;
    if (bytes == null || bytes.length > 1024 * 1024) {
      if (mounted) setState(() => _error = 'Choose a key file smaller than 1 MB.');
      return;
    }
    String pem;
    try {
      pem = utf8.decode(bytes);
    } catch (_) {
      if (mounted) setState(() => _error = 'SSH key must be an OpenSSH text file.');
      return;
    }
    final existing = await _store.exists;
    if (existing && mounted) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Replace the phone SSH key?'),
          content: const Text('Computers authorized for the current public key '
              'will stop accepting this iPhone until you authorize the imported key.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false),
                child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialog, true),
                child: const Text('Replace key')),
          ],
        ),
      );
      if (replace != true) return;
    }
    String? passphrase;
    if (SSHKeyPair.isEncryptedPem(pem)) {
      if (!mounted) return;
      passphrase = await _askPassphrase();
      if (passphrase == null) return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await _store.importPem(pem, passphrase: passphrase);
      await _refresh();
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Could not import this key. Only valid OpenSSH Ed25519 keys are supported.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('My SSH Key')),
    body: ListView(padding: const EdgeInsets.all(18), children: [
      const Icon(Icons.key, size: 48),
      const SizedBox(height: 16),
      const Text('TapTether SSH identity',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      const Text('A separate Ed25519 key for logging in to your computers '
          'over SSH. Its private key remains in iOS Keychain / Android secure storage.'),
      const SizedBox(height: 20),
      if (_error != null) Text(_error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error)),
      if (_publicLine == null)
        const Text('No SSH key on this phone yet.')
      else ...[
        const Text('Public key — safe to share with your own computers:'),
        const SizedBox(height: 8),
        SelectableText(_publicLine!, maxLines: 5),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: _publicLine!));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Public SSH key copied')),
              );
            }
          },
          icon: const Icon(Icons.copy), label: const Text('Copy Public Key'),
        ),
      ],
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _busy || _publicLine != null ? null : _generate,
        icon: const Icon(Icons.add), label: const Text('Generate SSH Key'),
      ),
      OutlinedButton.icon(
        onPressed: _busy ? null : _import,
        icon: const Icon(Icons.upload_file), label: const Text('Import SSH Key from Files'),
      ),
      const SizedBox(height: 18),
      const Text('Initial authorization: paste the public key into the '
          'target Ubuntu user’s ~/.ssh/authorized_keys using an existing SSH '
          'session, or use the password-based TapTether installer and select '
          '“Authorize phone SSH key”. Afterward choose SSH Key in the installer.'),
      const SizedBox(height: 12),
      const Text('The SSH host fingerprint must still be independently verified. '
          'Importing a key makes a decrypted copy available to TapTether’s OS '
          'secure storage; the original file remains wherever you selected it.'),
    ]),
  );
}
