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

  Future<int> openRowCount(String table, int timerId) async {
    final db = await DB.database;
    final rows = await db.query(table,
        columns: ['id'], where: 'timer_id = ? AND end_at_ms IS NULL', whereArgs: [timerId]);
    return rows.length;
  }

  test('starting an already running timer does not open a second session', () async {
    final id = await DB.createTimer('Double start', 'Product');
    await DB.start(id);
    await DB.start(id);

    expect(await openRowCount('total_sessions', id), 1);
    expect(await openRowCount('partial_segments', id), 1);
  });

  test('two concurrent starts still open only one session', () async {
    final id = await DB.createTimer('Concurrent start', 'Product');
    await Future.wait([DB.start(id), DB.start(id)]);

    expect(await openRowCount('total_sessions', id), 1);
    expect(await openRowCount('partial_segments', id), 1);
  });

  test('resuming twice does not open a second partial segment', () async {
    final id = await DB.createTimer('Double resume', 'Product');
    await DB.start(id);
    await DB.pausePartial(id);
    await DB.resumePartial(id);
    await DB.resumePartial(id);

    expect(await openRowCount('partial_segments', id), 1);
  });

  test('stop closes every open row, including ones leaked by older versions', () async {
    final id = await DB.createTimer('Leaked rows', 'Product');
    await DB.start(id);

    final db = await DB.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('partial_segments', {'timer_id': id, 'start_at_ms': now, 'end_at_ms': null});
    await db.insert('total_sessions', {'timer_id': id, 'start_at_ms': now, 'end_at_ms': null});

    await DB.stop(id);

    expect(await openRowCount('partial_segments', id), 0);
    expect(await openRowCount('total_sessions', id), 0);
  });

  test('deleting the running session from a report deactivates the timer', () async {
    final id = await DB.createTimer('Running', 'Product');
    await DB.start(id);

    final session = (await DB.getTotalSessionsForTimer(id)).single;
    await DB.deleteReportEntry(
      timerId: id,
      totalSessionId: session.id,
      sessionStartMs: session.startAt.millisecondsSinceEpoch,
      sessionEndMs: DateTime.now().millisecondsSinceEpoch,
    );

    final timer = (await DB.getTimers()).firstWhere((t) => t.id == id);
    expect(timer.isTotalActive, isFalse, reason: 'timer must not stay flagged as running');
    expect(timer.isPartialActive, isFalse);
    expect(await DB.getTotalSessionsForTimer(id), isEmpty);
    expect(await DB.getPartialSegmentsForTimer(id), isEmpty,
        reason: 'the open segment belongs to the deleted session');
  });

  test('deleting a finished session leaves other timers untouched', () async {
    final keep = await DB.createTimer('Keep', 'Product');
    await DB.start(keep);

    final id = await DB.createTimer('Finished', 'Product');
    await DB.start(id);
    await DB.stop(id);

    final session = (await DB.getTotalSessionsForTimer(id)).single;
    await DB.deleteReportEntry(
      timerId: id,
      totalSessionId: session.id,
      sessionStartMs: session.startAt.millisecondsSinceEpoch,
      sessionEndMs: session.endAt!.millisecondsSinceEpoch,
    );

    final kept = (await DB.getTimers()).firstWhere((t) => t.id == keep);
    expect(kept.isTotalActive, isTrue);
    expect(await openRowCount('total_sessions', keep), 1);
    await DB.stop(keep);
  });

  group('day-scoped auto-stop', () {
    // A fixed point inside a work day, so day boundaries are exercised without
    // the test depending on the wall clock it happens to run at.
    final today = DateTime(2026, 8, 20);
    int at(int hour, [int minute = 0]) =>
        DateTime(today.year, today.month, today.day, hour, minute).millisecondsSinceEpoch;
    int yesterdayAt(int hour) =>
        DateTime(today.year, today.month, today.day - 1, hour).millisecondsSinceEpoch;
    const sevenHours = 7 * 3600;

    setUp(() => DB.nowMs = () => at(18));
    tearDown(() => DB.nowMs = () => DateTime.now().millisecondsSinceEpoch);

    Future<int> autoStopDoneMs(int timerId) async {
      final db = await DB.database;
      final rows = await db.query('timers',
          columns: ['auto_stop_done_ms'], where: 'id = ?', whereArgs: [timerId]);
      return rows.first['auto_stop_done_ms'] as int;
    }

    /// Seeds a timer that is running with an auto-stop limit, its recorded
    /// sessions and its worked segments (`null` end = still open).
    Future<int> seedTimer(
      String name, {
      required int limitSec,
      required List<(int, int?)> sessions,
      required List<(int, int?)> segments,
      int doneMs = 0,
    }) async {
      final id = await DB.createTimer(name, 'Product', autoStopSec: limitSec);
      final db = await DB.database;
      await db.update(
          'timers',
          {'is_total_active': 1, 'is_partial_active': 1, 'auto_stop_done_ms': doneMs},
          where: 'id = ?',
          whereArgs: [id]);
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

    test('the limit survives a stop and a restart on the same day', () async {
      // The reported bug: stopping over the midday break and starting the
      // timer again handed out a fresh budget, so a 7h limit let the timer run
      // for 4h + 7h = 11h.
      final id = await seedTimer(
        'Restart after break',
        limitSec: sevenHours,
        sessions: [(at(8), at(12)), (at(13), null)],
        segments: [(at(8), at(12)), (at(13), null)],
      );

      final timer = (await DB.getTimers()).firstWhere((t) => t.id == id);
      expect(timer.isTotalActive, isFalse, reason: "the day's 7h were worked by 16:00");
      expect(timer.isPartialActive, isFalse);

      final worked = (await DB.getPartialSegmentsForTimer(id))
          .fold<Duration>(Duration.zero, (a, seg) => a + seg.endAt!.difference(seg.startAt));
      expect(worked, const Duration(hours: 7),
          reason: 'the budget belongs to the day, not to each session on its own');

      final open = (await DB.getTotalSessionsForTimer(id)).last;
      expect(open.endAt!.millisecondsSinceEpoch, at(16));
      expect(await autoStopDoneMs(id), at(16));
    });

    test('the limit survives a pause and a resume', () async {
      final id = await seedTimer(
        'Pause and resume',
        limitSec: sevenHours,
        sessions: [(at(8), null)],
        segments: [(at(8), at(12)), (at(13), null)],
      );

      final timer = (await DB.getTimers()).firstWhere((t) => t.id == id);
      expect(timer.isTotalActive, isFalse);
      final open = (await DB.getTotalSessionsForTimer(id)).single;
      expect(open.endAt!.millisecondsSinceEpoch, at(16),
          reason: 'the hour-long break must not push the stop moment back');
    });

    test('a session started after the limit fired is left running', () async {
      final id = await seedTimer(
        'Deliberate overtime',
        limitSec: sevenHours,
        sessions: [(at(8), at(16)), (at(17), null)],
        segments: [(at(8), at(16)), (at(17), null)],
        doneMs: at(16),
      );

      final timer = (await DB.getTimers()).firstWhere((t) => t.id == id);
      expect(timer.isTotalActive, isTrue,
          reason: 'the limit fires once a day, not on every restart after it');
      expect((await DB.getTotalSessionsForTimer(id)).last.endAt, isNull);
    });

    test('a restart after an unnoticed overrun keeps its time and arms the next day', () async {
      // Budget already spent before the open session started, with the
      // auto-stop never given a chance to fire (app closed). Cutting the new
      // session back would delete time the user knowingly worked.
      final id = await seedTimer(
        'Unnoticed overrun',
        limitSec: sevenHours,
        sessions: [(at(8), at(16)), (at(17), null)],
        segments: [(at(8), at(16)), (at(17), null)],
      );

      final timer = (await DB.getTimers()).firstWhere((t) => t.id == id);
      expect(timer.isTotalActive, isTrue);
      expect((await DB.getPartialSegmentsForTimer(id)).last.endAt, isNull);
      expect(await autoStopDoneMs(id), at(18), reason: "today's limit is spent");
    });

    test("yesterday's auto-stop does not disarm today's limit", () async {
      final id = await seedTimer(
        'New day',
        limitSec: sevenHours,
        sessions: [(at(8), null)],
        segments: [(at(8), null)],
        doneMs: yesterdayAt(16),
      );

      final timer = (await DB.getTimers()).firstWhere((t) => t.id == id);
      expect(timer.isTotalActive, isFalse,
          reason: 'a limit that fired on an earlier day must be armed again');
      expect((await DB.getTotalSessionsForTimer(id)).single.endAt!.millisecondsSinceEpoch, at(15));
    });

    test('a night shift keeps one budget across midnight', () async {
      DB.nowMs = () => at(3);
      final id = await seedTimer(
        'Night shift',
        limitSec: sevenHours,
        sessions: [(yesterdayAt(20), null)],
        segments: [(yesterdayAt(20), null)],
      );

      final timer = (await DB.getTimers()).firstWhere((t) => t.id == id);
      expect(timer.isTotalActive, isFalse);
      expect((await DB.getTotalSessionsForTimer(id)).single.endAt!.millisecondsSinceEpoch, at(3),
          reason: 'midnight must not hand out a second budget mid-shift');
      expect(await openRowCount('partial_segments', id), 0,
          reason: 'a segment left open on a stopped timer would count up forever');
    });

    test('remaining budget counts the whole day, not the current session', () async {
      final id = await seedTimer(
        'Remaining',
        limitSec: sevenHours,
        sessions: [(at(8), at(12)), (at(13), null)],
        segments: [(at(8), at(12)), (at(13), at(14))],
      );
      // 4h before the break plus 1h after it: 5h of the 7h budget are gone.
      final timer = (await DB.getTimers()).firstWhere((t) => t.id == id);
      expect(timer.isTotalActive, isTrue);
      expect(await DB.getAutoStopRemaining(timer), const Duration(hours: 2));
    });

    test('the auto-stop window covers the day, and the whole night shift', () {
      expect(autoStopWindowStartMs(sessionStartMs: at(7), nowMs: at(18)),
          DateTime(2026, 8, 20).millisecondsSinceEpoch);
      expect(autoStopWindowStartMs(sessionStartMs: yesterdayAt(22), nowMs: at(3)),
          DateTime(2026, 8, 19).millisecondsSinceEpoch);
    });
  });

  test('auto-stop leaves no open segment and credits no time past the limit', () async {
    final id = await DB.createTimer('Auto stop', 'Product', autoStopSec: 60);
    final db = await DB.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final sessionStart = now - 600000; // session opened ten minutes ago

    await db.update('timers', {'is_total_active': 1, 'is_partial_active': 1},
        where: 'id = ?', whereArgs: [id]);
    await db.insert('total_sessions',
        {'timer_id': id, 'start_at_ms': sessionStart, 'end_at_ms': null});
    // Five worked minutes, so the 60s limit was reached one minute in...
    await db.insert('partial_segments',
        {'timer_id': id, 'start_at_ms': sessionStart, 'end_at_ms': sessionStart + 300000});
    // ...then a pause, and a resume that opened a segment after the limit.
    await db.insert('partial_segments',
        {'timer_id': id, 'start_at_ms': sessionStart + 400000, 'end_at_ms': null});

    final timer = (await DB.getTimers()).firstWhere((t) => t.id == id);
    expect(timer.isTotalActive, isFalse);
    expect(await openRowCount('partial_segments', id), 0,
        reason: 'a segment left open on a stopped timer would count up forever');

    final segments = await DB.getPartialSegmentsForTimer(id);
    final worked = segments.fold<Duration>(
        Duration.zero, (a, s) => a + s.endAt!.difference(s.startAt));
    expect(worked, const Duration(seconds: 60));

    final session = (await DB.getTotalSessionsForTimer(id)).single;
    expect(session.endAt!.millisecondsSinceEpoch, sessionStart + 60000);
  });
}
