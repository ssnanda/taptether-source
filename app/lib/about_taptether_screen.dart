import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const tapTetherWebsite = 'https://taptether.com';
const tapTetherDownloads =
    'https://github.com/ssnanda/taptether.com/releases/tag/current';

Future<void> openTapTetherLink(String address) async {
  final launched = await launchUrl(
    Uri.parse(address), mode: LaunchMode.externalApplication);
  if (!launched) throw StateError('Could not open the website.');
}

class AboutTapTetherScreen extends StatelessWidget {
  const AboutTapTetherScreen({super.key, required this.version});
  final String version;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('About TapTether')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      Center(child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Image.asset('assets/branding/taptether.png',
            width: 84, height: 84))),
      const SizedBox(height: 16),
      Text('Your devices. Your control. Your network.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 10),
      const Text(
        'One remote for your computers and TVs. Control a Mac, Windows '
        'or Ubuntu computer—or your LG webOS TV—over your local Wi-Fi.',
        textAlign: TextAlign.center),
      const SizedBox(height: 10),
      const Text(
        'No TapTether account. No cloud relay. No analytics. '
        'Pair once and stay in control.',
        textAlign: TextAlign.center),
      const SizedBox(height: 22),
      ListTile(
        leading: const Icon(Icons.language),
        title: const Text('TapTether.com'),
        subtitle: const Text('Website'),
        trailing: const Icon(Icons.open_in_new, size: 18),
        onTap: () => openTapTetherLink(tapTetherWebsite)),
      const Divider(height: 1),
      ListTile(
        leading: const Icon(Icons.download_outlined),
        title: const Text('Download desktop agents'),
        subtitle: const Text('macOS, Ubuntu and Windows'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(context,
          MaterialPageRoute<void>(
            builder: (_) => const AgentDownloadsScreen()))),
      const Divider(height: 1),
      ListTile(
        leading: const Icon(Icons.system_update_alt),
        title: const Text('Latest releases'),
        trailing: const Icon(Icons.open_in_new, size: 18),
        onTap: () => openTapTetherLink(tapTetherDownloads)),
      const SizedBox(height: 24),
      Center(child: Text('Version $version',
        style: Theme.of(context).textTheme.bodySmall)),
    ]),
  );
}

class AgentDownloadsScreen extends StatelessWidget {
  const AgentDownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Download agents')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      Text('Control your computer from your phone.',
          style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text('Install the TapTether agent on your computer, '
          'then pair it with your phone on the same Wi-Fi. '
          'LG webOS TVs do not need an agent.'),
      const SizedBox(height: 18),
      for (final platform in const [
        ('macOS', Icons.laptop_mac, 'Intel and Apple Silicon'),
        ('Ubuntu', Icons.computer, 'AMD64 and ARM64'),
        ('Windows', Icons.desktop_windows_outlined, '64-bit installers'),
      ])
        Card(child: ListTile(
          leading: Icon(platform.$2),
          title: Text(platform.$1),
          subtitle: Text(platform.$3),
          trailing: const Icon(Icons.open_in_new),
          onTap: () => openTapTetherLink(tapTetherDownloads),
        )),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => openTapTetherLink(tapTetherWebsite),
        icon: const Icon(Icons.language),
        label: const Text('Visit TapTether.com')),
      const SizedBox(height: 12),
      const Text('Downloads are hosted on our public GitHub release page. '
          'Only the latest installers are published.'),
    ]),
  );
}
