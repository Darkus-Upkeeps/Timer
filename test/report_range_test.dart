import 'package:flutter_test/flutter_test.dart';
import 'package:work_timer/report_range.dart';

void main() {
  test('month reports can target a full previous calendar month', () {
    final range = reportRangeFor(
      period: 'month',
      now: DateTime(2026, 6, 2, 10, 30),
      selectedMonth: DateTime(2026, 4, 15),
    );

    expect(range.start, DateTime(2026, 4, 1));
    expect(range.end, DateTime(2026, 5, 1));
  });

  test('current month reports still end at now', () {
    final now = DateTime(2026, 6, 2, 10, 30);
    final range = reportRangeFor(
      period: 'month',
      now: now,
      selectedMonth: DateTime(2026, 6, 1),
    );

    expect(range.start, DateTime(2026, 6, 1));
    expect(range.end, now);
  });
}
