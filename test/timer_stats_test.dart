import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:work_timer/main.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dbPath = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dbPath, 'work_timer.db'));
  });

  // A fixed evening inside a work day, so the day rollover is exercised
  // without the test depending on the wall clock it runs at.
  final today = DateTime(2026, 8, 20);
  int at(int hour, [int minute = 0]) =>
      DateTime(today.year, today.month, today.day, hour, minute).millisecondsSinceEpoch;
  int yesterdayAt(int hour) =>
      DateTime(today.year, today.month, today.day - 1, hour).millisecondsSinceEpoch;

  setUp(() => DB.nowMs = () => at(18));
  tearDown(() => DB.nowMs = () => DateTime.now().millisecondsSinceEpoch);

  Future<WorkTimer> reload(int id) async =>
      (await DB.getTimers()).firstWhere((t) => t.id == id);

  /// Seeds a stopped timer with recorded sessions and worked segments.
  Future<int> seedTimer(
    String name, {
    required List<(int, int?)> sessions,
    required List<(int, int?)> segments,
    bool running = false,
  }) async {
    final id = await DB.createTimer(name, 'Product');
    final db = await DB.database;
    if (running) {
      await db.update('timers', {'is_total_active': 1, 'is_partial_active': 1},
          where: 'id = ?', whereArgs: [id]);
    }
    for (final (startMs, endMs) in sessions) {
      await db.insert('total_sessions',
          {'timer_id': id, 'start_at_ms': startMs, 'end_at_ms': endMs});
    }
    for (final (startMs, endMs) in segments) {
      await db.insert('partial_segments',
          {'timer_id': id, 'start_at_ms': startMs, 'end_at_ms': endMs});
    }
    return id;
  }

  test("work done today is shown as today's partial", () async {
    final id = await seedTimer(
      'Today',
      sessions: [(at(8), at(16))],
      segments: [(at(8), at(12)), (at(13), at(16))],
    );

    final stats = await computeStats(await reload(id));
    expect(stats.partialToday, const Duration(hours: 7));
    expect(partialLabel(stats), 'today');
  });

  test("yesterday's work keeps showing instead of dropping to zero", () async {
    // The reported bug: after the day rolled over, the card showed 0:00:00
    // for every timer while the reports still listed the hours.
    final id = await seedTimer(
      'Yesterday',
      sessions: [(yesterdayAt(8), yesterdayAt(16))],
      segments: [(yesterdayAt(8), yesterdayAt(12)), (yesterdayAt(13), yesterdayAt(16))],
    );

    final stats = await computeStats(await reload(id));
    expect(stats.partialToday, const Duration(hours: 7));
    expect(stats.partialDay, DateTime(today.year, today.month, today.day - 1));
    expect(partialLabel(stats), '19.08.',
        reason: 'the card has to name the day it is showing');
  });

  test('a running night shift is not cut in half at midnight', () async {
    DB.nowMs = () => at(3);
    final id = await seedTimer(
      'Night shift',
      sessions: [(yesterdayAt(20), null)],
      segments: [(yesterdayAt(20), null)],
      running: true,
    );

    final stats = await computeStats(await reload(id));
    expect(stats.partialToday, const Duration(hours: 7),
        reason: 'the shift started at 20:00 and it is now 03:00');
    expect(partialLabel(stats), '19.08.',
        reason: 'the shift belongs to the day it started in, not to "today"');
  });

  test('a timer that worked today and yesterday shows only today', () async {
    final id = await seedTimer(
      'Both days',
      sessions: [(yesterdayAt(8), yesterdayAt(16)), (at(9), at(11))],
      segments: [(yesterdayAt(8), yesterdayAt(16)), (at(9), at(11))],
    );

    final stats = await computeStats(await reload(id));
    expect(stats.partialToday, const Duration(hours: 2));
    expect(partialLabel(stats), 'today');
  });

  test('a correction applies to its own day only', () async {
    final id = await seedTimer(
      'Corrected',
      sessions: [(yesterdayAt(8), yesterdayAt(16))],
      segments: [(yesterdayAt(8), yesterdayAt(16))],
    );
    final db = await DB.database;
    // Corrected yesterday: 8h recorded, 7h30 actually worked.
    await db.update(
        'timers',
        {'partial_adjust_sec': -1800, 'partial_adjust_at_ms': yesterdayAt(17)},
        where: 'id = ?', whereArgs: [id]);

    final yesterdayStats = await computeStats(await reload(id));
    expect(yesterdayStats.partialToday, const Duration(hours: 7, minutes: 30));

    // A new day of work must start from the recorded time, not from the
    // correction — subtracting it again would pin the card near zero.
    await db.insert('partial_segments',
        {'timer_id': id, 'start_at_ms': at(9), 'end_at_ms': at(10)});
    final todayStats = await computeStats(await reload(id));
    expect(todayStats.partialToday, const Duration(hours: 1));
    expect(partialLabel(todayStats), 'today');
  });

  test('a subtracting correction cannot pin later days at zero', () async {
    final id = await seedTimer(
      'Pinned',
      sessions: [(yesterdayAt(8), yesterdayAt(16))],
      segments: [(yesterdayAt(8), yesterdayAt(16)), (at(9), at(9, 30))],
    );
    final db = await DB.database;
    await db.update(
        'timers',
        {'partial_adjust_sec': -3600, 'partial_adjust_at_ms': yesterdayAt(17)},
        where: 'id = ?', whereArgs: [id]);

    final stats = await computeStats(await reload(id));
    expect(stats.partialToday, const Duration(minutes: 30),
        reason: "yesterday's correction must not eat into today's half hour");
  });

  test('editing the correction dates it to the day it was entered', () async {
    final id = await seedTimer(
      'Dated',
      sessions: [(at(8), at(16))],
      segments: [(at(8), at(16))],
    );

    await DB.updateTimer(id, 'Dated', 'Product', partialAdjustSec: -1800);
    var timer = await reload(id);
    expect(startOfDayMs(timer.partialAdjustAtMs), startOfDayMs(DB.nowMs()),
        reason: 'a new correction belongs to the day it was entered');
    expect((await computeStats(timer)).partialToday, const Duration(hours: 7, minutes: 30));

    // Saving the dialog again without touching the correction must not move it.
    final stamped = timer.partialAdjustAtMs;
    await DB.updateTimer(id, 'Renamed', 'Product', partialAdjustSec: -1800);
    timer = await reload(id);
    expect(timer.partialAdjustAtMs, stamped);

    // Clearing the correction clears its date too.
    await DB.updateTimer(id, 'Renamed', 'Product', partialAdjustSec: 0);
    timer = await reload(id);
    expect(timer.partialAdjustAtMs, 0);
    expect((await computeStats(timer)).partialToday, const Duration(hours: 8));
  });
}
