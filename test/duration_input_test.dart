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
}
