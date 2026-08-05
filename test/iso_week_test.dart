import 'package:flutter_test/flutter_test.dart';
import 'package:work_timer/main.dart';

void main() {
  // 2026 starts on a Thursday, so every ISO Thursday sits an exact multiple of
  // seven days after Jan 1. The old implementation measured that gap with a
  // Duration on local dates, which loses an hour at the March DST change and
  // truncated every week from spring to autumn down by one.
  test('ISO week numbers are exact across a DST change', () {
    expect(isoWeekNumber(DateTime(2026, 1, 1)), 1); // Thursday, week 1
    expect(isoWeekNumber(DateTime(2026, 3, 23)), 13); // before the switch
    expect(isoWeekNumber(DateTime(2026, 3, 30)), 14); // after the switch
    expect(isoWeekNumber(DateTime(2026, 5, 14)), 20);
    expect(isoWeekNumber(DateTime(2026, 10, 26)), 44);
  });

  test('every day of a week reports the same number', () {
    for (var day = 11; day <= 17; day++) {
      expect(isoWeekNumber(DateTime(2026, 5, day)), 20, reason: 'May $day');
    }
  });

  test('weeks spanning a year boundary belong to the year of their Thursday', () {
    expect(isoWeekNumber(DateTime(2026, 12, 28)), 53); // 2026 has 53 weeks
    expect(isoWeekNumber(DateTime(2027, 1, 3)), 53); // still 2026's last week
    expect(isoWeekNumber(DateTime(2027, 1, 4)), 1); // first Monday of 2027 W1
  });

  test('weekStartOf returns the Monday of the containing week', () {
    expect(weekStartOf(DateTime(2026, 5, 14, 17, 30)), DateTime(2026, 5, 11));
    expect(weekStartOf(DateTime(2026, 5, 11)), DateTime(2026, 5, 11));
    expect(weekStartOf(DateTime(2026, 5, 17, 23, 59)), DateTime(2026, 5, 11));
  });
}
