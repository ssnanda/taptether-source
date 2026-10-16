import 'package:flutter/material.dart';

/// A single compact navigation row. The remote's three screen views are
/// secondary modes of Remote, rather than three additional page tabs.
class RemoteModeBar extends StatelessWidget {
  const RemoteModeBar({
    super.key,
    required this.primaryMode,
    required this.visualMode,
    required this.captureAvailable,
    required this.onPrimaryMode,
    required this.onVisualMode,
  });

  final String primaryMode;
  final String visualMode;
  final bool captureAvailable;
  final ValueChanged<String> onPrimaryMode;
  final ValueChanged<String> onVisualMode;

  IconData get _visualIcon => switch (visualMode) {
    'snapshot' => Icons.photo_outlined,
    'live' => Icons.live_tv_outlined,
    _ => Icons.mouse_outlined,
  };

  Widget _tab(BuildContext context, String mode, IconData icon,
      String label) {
    final scheme = Theme.of(context).colorScheme;
    final selected = primaryMode == mode;
    return Expanded(child: Semantics(
      selected: selected,
      button: true,
      label: label,
      child: Material(
        color: selected ? scheme.primaryContainer :
            scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: ValueKey('primary-mode-$mode'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => onPrimaryMode(mode),
          child: SizedBox(height: 44, child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18,
                color: selected ? scheme.onPrimaryContainer :
                    scheme.onSurfaceVariant),
              const SizedBox(width: 5),
              Flexible(child: Text(label,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12, fontWeight: selected ?
                    FontWeight.w700 : FontWeight.w500,
                  color: selected ? scheme.onPrimaryContainer :
                      scheme.onSurfaceVariant))),
            ],
          )),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(key: const ValueKey('one-row-remote-navigation'),
      children: [
        _tab(context, 'remote', Icons.mouse_outlined, 'Remote'),
        const SizedBox(width: 3),
        _tab(context, 'presentation', Icons.slideshow_outlined, 'Slides'),
        const SizedBox(width: 3),
        _tab(context, 'media', Icons.smart_display_outlined, 'Media'),
        const SizedBox(width: 6),
        Material(
          color: primaryMode == 'remote'
              ? scheme.primaryContainer : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          child: PopupMenuButton<String>(
            key: const ValueKey('screen-view-mode-switcher'),
            tooltip: 'Trackpad, Snapshot or Live',
            enabled: primaryMode == 'remote',
            initialValue: visualMode,
            onSelected: onVisualMode,
            itemBuilder: (_) => [
              const PopupMenuItem<String>(
                value: 'trackpad',
                child: ListTile(dense: true, contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.mouse_outlined), title: Text('Trackpad')),
              ),
              PopupMenuItem<String>(
                value: 'snapshot', enabled: captureAvailable,
                child: const ListTile(dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.photo_outlined),
                  title: Text('Snapshot')),
              ),
              PopupMenuItem<String>(
                value: 'live', enabled: captureAvailable,
                child: const ListTile(dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.live_tv_outlined), title: Text('Live')),
              ),
            ],
            child: SizedBox(width: 52, height: 44,
              child: Row(mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(_visualIcon, size: 19),
                  const Icon(Icons.arrow_drop_down, size: 16),
                ]),
            ),
          ),
        ),
      ],
    );
  }
}
