class ReportRange {
  final DateTime start;
  final DateTime end;

  const ReportRange({required this.start, required this.end});
}

DateTime monthStart(DateTime date) => DateTime(date.year, date.month, 1);

bool isSameMonth(DateTime a, DateTime b) => a.year == b.year && a.month == b.month;

ReportRange reportRangeFor({
  required String period,
  required DateTime now,
  DateTime? selectedMonth,
}) {
  if (period == 'today') {
    return ReportRange(start: DateTime(now.year, now.month, now.day), end: now);
  }

  if (period == 'week') {
    final dayStart = DateTime(now.year, now.month, now.day);
    return ReportRange(start: dayStart.subtract(Duration(days: now.weekday - 1)), end: now);
  }

  final month = monthStart(selectedMonth ?? now);
  final currentMonth = monthStart(now);
  final end = isSameMonth(month, currentMonth) ? now : DateTime(month.year, month.month + 1, 1);
  return ReportRange(start: month, end: end);
}
