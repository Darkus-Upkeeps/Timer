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

  test('auto-stop input is read hours-first, not seconds-first', () {
    // The field is prefilled as HH:MM:SS, so a bare '8' means eight hours.
    // Reading it as eight seconds (parseDurationInputToSeconds) auto-stopped
    // the session moments after it started.
    expect(parseAutoStopToSeconds('8'), 8 * 3600);
    expect(parseAutoStopToSeconds('7.5'), 7 * 3600 + 1800);
    expect(parseAutoStopToSeconds('7,5'), 7 * 3600 + 1800);
    expect(parseAutoStopToSeconds('08:30'), 8 * 3600 + 1800);
    expect(parseAutoStopToSeconds('08:30:15'), 8 * 3600 + 1815);
  });

  test('auto-stop input round-trips through the field prefill', () {
    for (final seconds in [8 * 3600, 30 * 60, 12 * 3600 + 1815]) {
      expect(parseAutoStopToSeconds(fmt(Duration(seconds: seconds))), seconds);
    }
  });

  test('auto-stop treats empty and negative input as off', () {
    expect(parseAutoStopToSeconds(''), 0);
    expect(parseAutoStopToSeconds('abc'), 0);
    expect(parseAutoStopToSeconds('-4'), 0);
  });

  test('fmtBalance always renders an explicit sign', () {
    expect(fmtBalance(const Duration(hours: 2, minutes: 15)), '+02:15:00');
    expect(fmtBalance(const Duration(hours: -1, minutes: -30)), '-01:30:00');
    expect(fmtBalance(Duration.zero), '+00:00:00');
  });
}
