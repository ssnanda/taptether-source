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
    required this.onUbuntuInstalled,
    this.knownPlatform,
  });

  final String initialHost;
  final String? knownPlatform;
  final Future<bool> Function(InstalledAgent) onUbuntuInstalled;

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

  Future<void> _ubuntu() async {
    final ip = _address.text.trim();
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => UbuntuInstallScreen(
        initialHost: ip,
        onInstalled: widget.onUbuntuInstalled,
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
      appBar: AppBar(title: const Text('Install Agent')),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text('Install TapTether on a computer',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('One installer screen for all supported computer types. '
              'The OS is selected automatically when a trusted computer '
              'reports it. Otherwise choose it below.'),
          const SizedBox(height: 18),
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
              labelText: 'Computer LAN IP',
              helperText: 'The local network prefix is filled automatically',
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
            const Text('Choose a computer OS to see its installation method. '
                'An unpaired computer cannot be identified securely from '
                'its IP address alone.'),
          if (_platform == 'linux') ...[
            const Text('Ubuntu installation uses SSH and your saved phone '
                'SSH key or Ubuntu password. No cloud account needed.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: isPrivateIPv4(_address.text.trim()) ? _ubuntu : null,
              icon: const Icon(Icons.terminal),
              label: const Text('Install over SSH'),
            ),
          ],
          if (_platform == 'darwin') ...[
            const Text('Download the macOS TapTether Agent.app ZIP on the '
                'computer, open the app in Finder, and choose Install / '
                'Repair. macOS may request Accessibility permission.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _openMacDownload,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Open macOS agent download'),
            ),
          ],
          if (_platform == 'windows') ...[
            const Text('Windows agent support is on the later roadmap. '
                'Windows does not need SSH for basic local installation: '
                'a future signed installer will run on the Windows PC '
                'and pair with the phone using a QR code or pairing code. '
                'Remote Windows installation is not yet available.'),
          ],
        ],
      )),
    );
  }
}
