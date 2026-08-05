import 'package:flutter_test/flutter_test.dart';
import 'package:work_timer/main.dart';

void main() {
  test('parses positive duration input', () {
    expect(parseDurationInputToSeconds(''), 0);
    expect(parseDurationInputToSeconds('90'), 90);
    expect(parseDurationInputToSeconds('01:30'), 90);
    expect(parseDurationInputToSeconds('01:30:00'), 5400);
    expect(parseDurationInputToSeconds('+01:30:00'), 5400);
  });

  test('parses negative duration input as subtraction', () {
    expect(parseDurationInputToSeconds('-90'), -90);
    expect(parseDurationInputToSeconds('-01:30'), -90);
    expect(parseDurationInputToSeconds('-01:30:00'), -5400);
    expect(parseDurationInputToSeconds('- 01:30:00'), -5400);
    expect(parseDurationInputToSeconds('-'), 0);
  });

  test('fmtSigned renders negative durations with a single leading minus', () {
    expect(fmtSigned(const Duration(seconds: 5400)), '01:30:00');
    expect(fmtSigned(const Duration(seconds: -5400)), '-01:30:00');
    expect(fmtSigned(Duration.zero), '00:00:00');
  });

  test('parses weekly target input hours-first', () {
    expect(parseWeeklyTargetToSeconds(''), 0);
    expect(parseWeeklyTargetToSeconds('40'), 40 * 3600);
    expect(parseWeeklyTargetToSeconds('38.5'), 38 * 3600 + 1800);
    expect(parseWeeklyTargetToSeconds('38,5'), 38 * 3600 + 1800);
    expect(parseWeeklyTargetToSeconds('38:30'), 38 * 3600 + 1800);
    expect(parseWeeklyTargetToSeconds('38:30:15'), 38 * 3600 + 1815);
    expect(parseWeeklyTargetToSeconds('abc'), 0);
  });

  test('fmtBalance always renders an explicit sign', () {
    expect(fmtBalance(const Duration(hours: 2, minutes: 15)), '+02:15:00');
    expect(fmtBalance(const Duration(hours: -1, minutes: -30)), '-01:30:00');
    expect(fmtBalance(Duration.zero), '+00:00:00');
  });
}
