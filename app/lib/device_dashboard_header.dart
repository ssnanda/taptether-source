import 'package:flutter/material.dart';
import 'network_location.dart';

/// Compact, accessible controls for the saved-device dashboard.
/// Checking and locating share a single on-demand action.
class DeviceDashboardHeader extends StatelessWidget {
  const DeviceDashboardHeader({
    super.key,
    required this.showFilters,
    required this.locationFilter,
    required this.detectedLocation,
    required this.showOffline,
    required this.onlineComputerCount,
    required this.onlineTvCount,
    required this.locating,
    required this.onManage,
    required this.onLocationChanged,
    required this.onShowOfflineChanged,
    required this.onLocate,
  });

  final bool showFilters;
  final String locationFilter;
  final String? detectedLocation;
  final bool showOffline;
  final int onlineComputerCount;
  final int onlineTvCount;
  final bool locating;
  final VoidCallback onManage;
  final ValueChanged<String> onLocationChanged;
  final ValueChanged<bool> onShowOfflineChanged;
  final VoidCallback onLocate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final currentLocation = deviceLocations[detectedLocation];
    final onlineCount =
        '$onlineComputerCount ${onlineComputerCount == 1 ? 'computer' : 'computers'}'
        ' · $onlineTvCount ${onlineTvCount == 1 ? 'TV' : 'TVs'}';

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(
              'My Devices',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            )),
            IconButton.filledTonal(
              key: const ValueKey('manage-saved-devices'),
              tooltip: 'Manage saved devices',
              onPressed: onManage,
              icon: const Icon(Icons.tune_rounded, size: 21),
            ),
          ]),
          if (showFilters) ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: DropdownButtonFormField<String>(
                key: const ValueKey('device-location-filter'),
                initialValue: locationFilter,
                isExpanded: true,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.location_on_outlined, size: 20),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 14),
                  filled: true,
                  fillColor: colors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: colors.outlineVariant),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: colors.outlineVariant),
                  ),
                ),
                items: [
                  DropdownMenuItem(
                    value: 'automatic',
                    child: Text(currentLocation == null
                        ? 'Current network' : 'Current · $currentLocation',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  const DropdownMenuItem(
                    value: 'all', child: Text('All locations')),
                  for (final location in deviceLocations.entries)
                    DropdownMenuItem(
                      value: location.key,
                      child: Text(location.value),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) onLocationChanged(value);
                },
              )),
              const SizedBox(width: 10),
              IconButton.filled(
                key: const ValueKey('locate-saved-devices'),
                tooltip: locating
                    ? 'Locating saved devices'
                    : 'Refresh and locate saved devices',
                onPressed: locating ? null : onLocate,
                icon: locating
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.refresh_rounded, size: 23),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              FilterChip(
                key: const ValueKey('show-offline-devices'),
                label: const Text('Show offline'),
                selected: showOffline,
                onSelected: onShowOfflineChanged,
                showCheckmark: true,
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              Expanded(child: Tooltip(
                message: 'Devices currently online',
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Icon(Icons.circle, size: 7,
                      color: colors.primary),
                    const SizedBox(width: 5),
                    Flexible(child: Text(
                      onlineCount,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    )),
                  ],
                ),
              )),
            ]),
          ],
        ],
      ),
    );
  }
}
