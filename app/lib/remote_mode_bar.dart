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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final selectedForeground = Colors.white;
    return Expanded(flex: 4, child: Semantics(
      selected: selected,
      button: true,
      label: label,
      child: Material(
        color: selected ? const Color(0xFF078F98) :
            (dark ? scheme.surfaceContainerHigh : scheme.surface),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          key: ValueKey('primary-mode-$mode'),
          borderRadius: BorderRadius.circular(20),
          onTap: () => onPrimaryMode(mode),
          child: SizedBox(height: 49, child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18,
                color: selected ? selectedForeground :
                    scheme.onSurfaceVariant),
              const SizedBox(width: 5),
              Flexible(child: Text(label,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12, fontWeight: selected ?
                    FontWeight.w700 : FontWeight.w500,
                  color: selected ? selectedForeground :
                      scheme.onSurfaceVariant))),
            ],
          )),
        ),
      ),
    ));
  }

  /// Remote's main touch target and view selector share one connected
  /// surface. The mode picker is never disabled on Slides or Media: choosing
  /// Trackpad/Snapshot/Live activates Remote in the parent's callback.
  Widget _remoteSplitTab(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = primaryMode == 'remote';
    final foreground = selected
        ? Colors.white : scheme.onSurfaceVariant;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Expanded(flex: 7, child: Material(
      color: selected ? const Color(0xFF048DA0) :
          (dark ? scheme.surfaceContainerHigh : scheme.surface),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(height: 49, child: Row(children: [
        Expanded(child: Semantics(
          button: true, selected: selected, label: 'Remote',
          child: InkWell(
            key: const ValueKey('primary-mode-remote'),
            onTap: () => onPrimaryMode('remote'),
            child: SizedBox(height: 49,
              child: Row(mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.mouse_outlined, size: 18, color: foreground),
                  const SizedBox(width: 5),
                  Flexible(child: Text('Remote', maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: foreground))),
                ])),
          ),
        )),
        SizedBox(height: 25, child: VerticalDivider(
          width: 1, thickness: 1,
          color: foreground.withValues(alpha: 0.3))),
        PopupMenuButton<String>(
          key: const ValueKey('screen-view-mode-switcher'),
          tooltip: 'Remote view: Trackpad, Snapshot, Live',
          initialValue: visualMode,
          onSelected: onVisualMode,
          itemBuilder: (_) => [
            const PopupMenuItem<String>(
              value: 'trackpad',
              child: ListTile(dense: true, contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.mouse_outlined), title: Text('Trackpad'))),
            PopupMenuItem<String>(
              value: 'snapshot', enabled: captureAvailable,
              child: const ListTile(dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.photo_outlined),
                title: Text('Snapshot'))),
            PopupMenuItem<String>(
              value: 'live', enabled: captureAvailable,
              child: const ListTile(dense: true, contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.live_tv_outlined), title: Text('Live'))),
          ],
          child: SizedBox(width: 36, height: 49,
            child: Row(mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(_visualIcon, size: 17, color: foreground),
                Icon(Icons.arrow_drop_down, size: 13, color: foreground),
              ]),
          ),
        ),
      ])),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Row(key: const ValueKey('one-row-remote-navigation'),
      children: [
        _remoteSplitTab(context),
        const SizedBox(width: 7),
        _tab(context, 'presentation', Icons.slideshow_outlined, 'Slides'),
        const SizedBox(width: 7),
        _tab(context, 'media', Icons.smart_display_outlined, 'Media'),
      ],
    );
  }
}
