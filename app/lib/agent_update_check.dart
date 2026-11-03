import 'package:flutter/material.dart';

/// Compare published and installed versions without assuming that the mobile
/// app's version is the agent version. Unknown versions never authorize
/// an automatic update.
enum AgentUpdateState { updateAvailable, upToDate, unavailable }

/// Agent versions are independent of the iOS app. A version is trusted only
/// when the named public binary assets match the published SHA-256 catalog.
class AgentReleaseCatalog {
  static const assetNames = <String, List<String>>{
    'darwin': [
      'TapTetherAgent-macOS-amd64.tar.gz',
      'TapTetherAgent-macOS-arm64.tar.gz',
    ],
    'linux': [
      'TapTetherAgent-Ubuntu-amd64.deb',
      'TapTetherAgent-Ubuntu-arm64.deb',
    ],
    'windows': [
      'TapTetherAgent-Windows-amd64.zip',
      'TapTetherAgent-Windows-arm64.zip',
    ],
  };

  static const _platformChannels = <String, (String, String)>{
    'darwin': ('macos-current', 'macOS'),
    'linux': ('ubuntu-current', 'Ubuntu'),
    'windows': ('windows-current', 'Windows'),
  };

  static final _versionPattern = RegExp(
    r'^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$',
  );
  static final _digestPattern = RegExp(r'^sha256:[a-fA-F0-9]{64}$');

  static String? verifiedCurrentVersion({
    required String platform,
    required Object? catalog,
    required Object? release,
  }) {
    final names = assetNames[platform];
    if (names == null || catalog is! Map || release is! Map) { return null; }
    if (catalog['schemaVersion'] != 1 || catalog['tag'] != 'current' ||
        release['tag_name'] != 'current' || release['assets'] is! List) {
      return null;
    }
    final platforms = catalog['platforms'];
    if (platforms is! Map || platforms[platform] is! Map) { return null; }
    final info = platforms[platform] as Map;
    final version = info['version'];
    final pinned = info['assets'];
    if (version is! String || !_versionPattern.hasMatch(version) ||
        pinned is! Map || pinned.length != names.length) { return null; }
    final assets = release['assets'] as List;
    for (final name in names) {
      final digest = pinned[name];
      if (digest is! String || !_digestPattern.hasMatch(digest)) { return null; }
      if (!_matchAsset(assets, name, digest, 'current')) { return null; }
    }
    return version;
  }

  /// Newer independent macOS, Ubuntu, and Windows agent releases report their
  /// own versions. Unknown feeds must never fall back to the mobile version.
  static String? verifiedPlatformVersion({
    required String platform,
    required Object? release,
  }) {
    final channel = _platformChannels[platform];
    final names = assetNames[platform];
    if (channel == null || names == null || release is! Map ||
        release['tag_name'] != channel.$1 ||
        release['name'] is! String || release['assets'] is! List) {
      return null;
    }
    final match = RegExp(
      r'^TapTether (Ubuntu|macOS|Windows) ([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+) '
      r'\(agent-only rolling downloads\)$',
    ).firstMatch(release['name'] as String);
    if (match == null || match.group(1) != channel.$2) { return null; }
    final assets = release['assets'] as List;
    for (final name in names) {
      final matches = assets.whereType<Map>()
          .where((entry) => entry['name'] == name).toList();
      if (matches.length != 1) { return null; }
      final digest = matches.single['digest'];
      if (digest is! String || !_digestPattern.hasMatch(digest) ||
          !_matchAsset(assets, name, digest, channel.$1)) { return null; }
    }
    return match.group(2);
  }

  static bool _matchAsset(List assets, String name, String digest, String tag) {
    final entries = assets.whereType<Map>()
        .where((entry) => entry['name'] == name).toList();
    if (entries.length != 1) { return false; }
    final item = entries.single;
    final size = item['size'];
    return size is num && size > 1024 &&
        item['digest'] == digest &&
        item['browser_download_url'] ==
            'https://github.com/ssnanda/taptether.com/releases/'
            'download/$tag/$name';
  }
}

class AgentUpdateCheck {
  const AgentUpdateCheck({required this.installed, required this.published});

  final String? installed;
  final String? published;

  static List<int>? _parts(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'^v?([0-9]+)\.([0-9]+)\.([0-9]+)(?:\+([0-9]+))?$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    return [
      for (var i = 1; i <= 4; i++) int.parse(match.group(i) ?? '0'),
    ];
  }

  AgentUpdateState get state {
    final current = _parts(installed);
    final latest = _parts(published);
    if (current == null || latest == null) {
      return AgentUpdateState.unavailable;
    }
    for (var i = 0; i < 4; i++) {
      if (latest[i] > current[i]) return AgentUpdateState.updateAvailable;
      if (latest[i] < current[i]) return AgentUpdateState.upToDate;
    }
    return AgentUpdateState.upToDate;
  }

  bool get canUpdate => state == AgentUpdateState.updateAvailable;
  String get installedLabel => installed ?? 'Could not verify';
  String get publishedLabel => published ?? 'Could not check';

  String get description {
    switch (state) {
      case AgentUpdateState.updateAvailable:
        return 'This update may briefly disconnect the computer. '
            'Existing pairing and local settings will be preserved.';
      case AgentUpdateState.upToDate:
        return 'Your computer agent is already up to date. '
            'No update is needed.';
      case AgentUpdateState.unavailable:
        return 'Unable to verify both versions. No automatic update will '
            'be started. Check the computer connection and try again.';
    }
  }
}

/// Saved-device update affordances are shown only for devices that were
/// authenticated as online and have a verified, strictly newer agent release.
/// Unknown installed/published versions, equal versions, and offline devices
/// must never show a speculative update icon.
bool showSavedAgentUpdate({
  required bool? online,
  required String? installed,
  required String? published,
}) => online == true &&
    AgentUpdateCheck(installed: installed, published: published).canUpdate;

/// The macOS agent responds to ping even if it cannot post keyboard/mouse
/// events; its authenticated control endpoint reports this specific error.
bool isMacAccessibilityError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('macos accessibility permission') ||
      message.contains('macos accessibility access');
}

class AgentUpdateDialog extends StatelessWidget {
  const AgentUpdateDialog({
    super.key,
    required this.computerName,
    required this.check,
  });

  final String computerName;
  final AgentUpdateCheck check;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('TapTether Agent · $computerName'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Installed version',
            style: Theme.of(context).textTheme.labelMedium),
        SelectableText(check.installedLabel,
            key: const ValueKey('agent-installed-version'),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Text('Latest published version',
            style: Theme.of(context).textTheme.labelMedium),
        SelectableText(check.publishedLabel,
            key: const ValueKey('agent-published-version'),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),
        Text(check.description, key: const ValueKey('agent-update-description')),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text(check.canUpdate ? 'Cancel' : 'Close'),
      ),
      if (check.canUpdate)
        FilledButton(
          key: const ValueKey('confirm-agent-update'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Update Agent'),
        ),
    ],
  );
}
