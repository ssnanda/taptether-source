import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/display_time.dart';

void main() {
  test('midnight and noon use 12 AM and 12 PM', () {
    expect(displayTimeAmPm(DateTime(2026, 11, 6, 0, 0)), '12:00 AM');
    expect(displayTimeAmPm(DateTime(2026, 11, 6, 12, 0)), '12:00 PM');
  });
  test('morning and evening use 12-hour clocks', () {
    expect(displayTimeAmPm(DateTime(2026, 11, 6, 9, 7)), '9:07 AM');
    expect(displayTimeAmPm(DateTime(2026, 11, 6, 21, 17)), '9:17 PM');
    expect(displayTimeAmPm(DateTime(2026, 11, 6, 23, 59)), '11:59 PM');
  });
  test('visible date-time retains date and adds AM/PM', () {
    expect(displayDateTimeAmPm(DateTime(2026, 11, 6, 21, 17)),
        '2026-11-06 9:17 PM');
    expect(displayDateTimeAmPm(DateTime(2026, 1, 2, 5, 4)),
        '2026-01-02 5:04 AM');
  });
}
