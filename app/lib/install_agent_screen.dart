import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'discovery.dart';
import 'lan_scan.dart';
import 'ssh_provisioner.dart';
import 'ubuntu_install_screen.dart';

/// Single OS-aware installer entry. Existing authenticated device metadata
/// selects the platform; for a fresh/unpaired host the user chooses the OS.
/// Windows has no supported agent installer yet and never assumes SSH.
class InstallAgentScreen extends StatefulWidget {
  const InstallAgentScreen({
    super.key,
    required this.initialHost,
    required this.onInstalled,
    this.knownPlatform,
    this.updateOnly = false,
  });

  final String initialHost;
  final String? knownPlatform;
  final bool updateOnly;
  final Future<bool> Function(InstalledAgent, String) onInstalled;

  @override
  State<InstallAgentScreen> createState() => _InstallAgentScreenState();
}

class _InstallAgentScreenState extends State<InstallAgentScreen> {
  late final _address = TextEditingController(text: widget.initialHost);
  String? _platform;

  @override
  void initState() {
    super.initState();
    if (const {'linux', 'darwin', 'windows'}.contains(widget.knownPlatform)) {
      _platform = widget.knownPlatform;
    }
    unawaited(_loadCurrentNetwork());
  }

  Future<void> _loadCurrentNetwork() async {
    if (isPrivateIPv4(_address.text.trim())) return;
    final local = await detectLanRange();
    if (mounted && local != null && !isPrivateIPv4(_address.text.trim())) {
      setState(() {
        _address.text = '${local.activePrefix}.';
        _address.selection = TextSelection.collapsed(
          offset: _address.text.length);
      });
    }
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _sshInstallOrUpdate() async {
    final ip = _address.text.trim();
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => UbuntuInstallScreen(
        initialHost: ip,
        isMac: _platform == 'darwin',
        updateOnly: widget.updateOnly,
        onInstalled: (installed) => widget.onInstalled(installed, _platform!),
      ),
    ));
  }

  Future<void> _openMacDownload() async {
    const link = 'https://github.com/ssnanda/taptether.com/releases/latest';
    final ok = await launchUrl(Uri.parse(link),
        mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not open the releases page.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.updateOnly ? 'Update Agent' : 'Install Agent')),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const SizedBox(height: 6),
          TextField(
            controller: _address,
            keyboardType: TextInputType.url,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              LengthLimitingTextInputFormatter(15),
            ],
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Computer IP address',
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            key: const ValueKey('install-platform'),
            initialValue: _platform,
            decoration: const InputDecoration(labelText: 'Computer OS'),
            items: const [
              DropdownMenuItem(value: 'linux', child: Text('Ubuntu / Linux')),
              DropdownMenuItem(value: 'darwin', child: Text('macOS')),
              DropdownMenuItem(value: 'windows', child: Text('Windows')),
            ],
            onChanged: (value) => setState(() => _platform = value),
          ),
          const SizedBox(height: 18),
          if (_platform == null)
            const ListTile(
              leading: Icon(Icons.devices_outlined),
              title: Text('Choose the computer operating system'),
            ),
          if (_platform == 'linux') ...[
            const Text('Connect using SSH. Saved pairings are preserved.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: isPrivateIPv4(_address.text.trim())
                  ? _sshInstallOrUpdate : null,
              icon: const Icon(Icons.terminal),
              label: Text(widget.updateOnly ? 'Update over SSH' : 'Install over SSH'),
            ),
          ],
          if (_platform == 'darwin') ...[
            const Text('Enable Remote Login on the Mac, then connect over SSH. '
                'First-time Screen Core installation needs the Mac app once; '
                'future agent updates preserve screen permissions.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: isPrivateIPv4(_address.text.trim())
                  ? _sshInstallOrUpdate : null,
              icon: const Icon(Icons.terminal),
              label: Text(widget.updateOnly
                  ? 'Update Mac over SSH' : 'Install Mac over SSH'),
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: _openMacDownload,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Get Mac app (one-time setup)'),
            ),
          ],
          if (_platform == 'windows') ...[
            const Text('Download the Windows ZIP, then run Install-TapTether.cmd '
                'and Show-Pairing.cmd on the computer.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _openMacDownload,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Download Windows agent'),
            ),
            if (widget.updateOnly)
              const Text('For paired Windows computers with the new agent, '
                  'use My Devices → Update Agent. Older versions can be '
                  'upgraded locally by running the downloaded installer.'),
          ],
        ],
      )),
    );
  }
}
