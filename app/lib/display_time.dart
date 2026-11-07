/// User-facing timestamps are always in local 12-hour time with AM/PM.
/// Machine-readable backup dates and diagnostic logs retain their original format.
String displayTimeAmPm(DateTime timestamp) {
  final time = timestamp.toLocal();
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${time.hour < 12 ? 'AM' : 'PM'}';
}

/// Compact backup and diagnostics date-time; 2026-11-06 9:17 PM.
String displayDateTimeAmPm(DateTime timestamp) {
  final date = timestamp.toLocal();
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day ${displayTimeAmPm(date)}';
}
