import 'package:flutter/material.dart';

/// One compact scope switch instead of a second oversized "My Devices"
/// panel, location dropdown, duplicate online totals and filter chip.
/// All Devices is inventory; This Network is reachability on current Wi-Fi.
class DeviceDashboardHeader extends StatelessWidget {
  const DeviceDashboardHeader({
    super.key,
    required this.allDevices,
    required this.onWifi,
    required this.locating,
    required this.onScopeChanged,
    required this.onManage,
    required this.onLocate,
  });

  final bool allDevices;
  final bool onWifi;
  final bool locating;
  final ValueChanged<bool> onScopeChanged;
  final VoidCallback onManage;
  final VoidCallback onLocate;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    Widget scope(String text, bool all, IconData icon, String id) {
      final selected = allDevices == all;
      return Expanded(child: Material(
        borderRadius: BorderRadius.circular(16),
        color: selected ? color.primary : color.surfaceContainerLow,
        child: InkWell(
          key: ValueKey(id),
          onTap: () => onScopeChanged(all),
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(height: 42, child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: selected
                  ? color.onPrimary : color.onSurfaceVariant),
              const SizedBox(width: 5),
              Flexible(child: Text(text, maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? color.onPrimary : color.onSurfaceVariant,
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ))),
            ],
          )),
        ),
      ));
    }
    return Row(
      key: const ValueKey('device-scope-header'),
      children: [
        scope('All Devices', true, Icons.devices_rounded,
            'device-scope-all'),
        const SizedBox(width: 7),
        scope('On This Network', false, Icons.wifi_rounded,
            'device-scope-network'),
        const SizedBox(width: 5),
        if (onWifi)
          IconButton(
            key: const ValueKey('locate-saved-devices'),
            tooltip: locating ? 'Locating saved devices' :
                'Refresh devices on this network',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 37, minHeight: 42),
            padding: EdgeInsets.zero,
            onPressed: locating ? null : onLocate,
            icon: locating
                ? const SizedBox(width: 19, height: 19,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded, size: 23),
          ),
        IconButton(
          key: const ValueKey('manage-saved-devices'),
          tooltip: 'Manage saved devices',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 37, minHeight: 42),
          padding: EdgeInsets.zero,
          onPressed: onManage,
          icon: const Icon(Icons.tune_rounded, size: 21),
        ),
      ],
    );
  }
}
