import 'package:flutter/material.dart';

/// Three compact shortcuts: saved inventory, current Wi-Fi, and thermostats.
/// Tooltip and semantics names keep icon-only navigation accessible.
class DeviceDashboardHeader extends StatelessWidget {
  const DeviceDashboardHeader({
    super.key,
    required this.allDevices,
    required this.onWifi,
    required this.locating,
    required this.onScopeChanged,
    required this.onThermostats,
    required this.onManage,
    required this.onLocate,
  });

  final bool allDevices;
  final bool onWifi;
  final bool locating;
  final ValueChanged<bool> onScopeChanged;
  final VoidCallback onThermostats;
  final VoidCallback onManage;
  final VoidCallback onLocate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    Widget shortcut({
      required String id,
      required String label,
      required IconData icon,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: Tooltip(
          message: label,
          child: Semantics(
            label: label,
            button: true,
            selected: selected,
            child: Material(
              borderRadius: BorderRadius.circular(14),
              color: selected ? colors.primary : colors.surfaceContainerLow,
              child: InkWell(
                key: ValueKey(id),
                onTap: onTap,
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  height: 42,
                  child: Center(
                    child: Icon(icon, size: 22,
                      color: selected ? colors.onPrimary : colors.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      key: const ValueKey('device-scope-header'),
      children: [
        shortcut(
          id: 'device-scope-all', label: 'All devices',
          icon: Icons.devices_rounded,
          selected: allDevices,
          onTap: () => onScopeChanged(true),
        ),
        const SizedBox(width: 7),
        shortcut(
          id: 'device-scope-network', label: 'On this network',
          icon: Icons.wifi_rounded,
          selected: !allDevices,
          onTap: () => onScopeChanged(false),
        ),
        const SizedBox(width: 7),
        shortcut(
          id: 'device-scope-thermostats', label: 'Thermostats',
          icon: Icons.thermostat_rounded,
          selected: false,
          onTap: onThermostats,
        ),
        const SizedBox(width: 5),
        if (onWifi)
          IconButton(
            key: const ValueKey('locate-saved-devices'),
            tooltip: locating
                ? 'Locating saved devices'
                : 'Refresh devices on this network',
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
