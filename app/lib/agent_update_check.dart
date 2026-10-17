import 'package:flutter/material.dart';

/// Compare published and installed versions without assuming that the mobile
/// app's version is the agent version. Unknown versions never authorize
/// an automatic update.
enum AgentUpdateState { updateAvailable, upToDate, unavailable }

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
