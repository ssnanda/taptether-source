import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/fridge_alerts.dart';

void main() {
  test('default and supported foreground intervals are explicit', () {
    expect(fridgeDefaultCheckMinutes, 15);
    expect(fridgeCheckIntervals, [1, 5, 15, 30, 60]);
    expect(fridgeCheckIntervals.toSet().length, fridgeCheckIntervals.length);
  });

  test('a one-minute foreground test becomes due after one minute', () {
    final start = DateTime.utc(2026, 10, 30, 10, 0);
    expect(fridgeCheckIsDue(start, null, 1), isTrue);
    expect(fridgeCheckIsDue(start, start, 1), isFalse);
    expect(fridgeCheckIsDue(
      start.add(const Duration(seconds: 59)), start, 1), isFalse);
    expect(fridgeCheckIsDue(
      start.add(const Duration(minutes: 1)), start, 1), isTrue);
  });

  test('longer intervals do not poll prematurely', () {
    final start = DateTime.utc(2026, 10, 30, 10, 0);
    expect(fridgeCheckIsDue(
      start.add(const Duration(minutes: 4)), start, 5), isFalse);
    expect(fridgeCheckIsDue(
      start.add(const Duration(minutes: 5)), start, 5), isTrue);
    expect(fridgeCheckIsDue(
      start.add(const Duration(minutes: 14)), start, 15), isFalse);
  });

  test('background scheduling respects the 15-minute floor', () {
    expect(fridgeBackgroundMinutes([]), 15);
    expect(fridgeBackgroundMinutes([1]), 15);
    expect(fridgeBackgroundMinutes([5, 30]), 15);
    expect(fridgeBackgroundMinutes([15, 60]), 15);
    expect(fridgeBackgroundMinutes([30, 60]), 30);
    expect(fridgeBackgroundMinutes([60]), 60);
  });
}
